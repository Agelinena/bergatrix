"""
berga-news worker
─────────────────
Jobs:
  • fetch_all_feeds  — every FETCH_INTERVAL_MINUTES (default 30)
  • run_digest       — cron 07:00 and 18:00 SP (10:00 and 21:00 UTC)
  • check_trigger    — every 60s (manual trigger from admin panel)
  • cleanup          — daily at 03:00 SP (06:00 UTC)
  • alive_marker     — every 60s
"""
import logging
import os
import signal
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

from apscheduler.schedulers.background import BackgroundScheduler
from sqlalchemy import desc

import clusterer
import content_prefetch
import fetcher
import summarizer
from sqlalchemy.orm import joinedload

from db import Article, Cluster, DigestRun, Feed, Setting, get_session, init_db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("worker")

FETCH_INTERVAL_MINUTES = int(os.environ.get("FETCH_INTERVAL_MINUTES", "30"))
DIGEST_WINDOW_HOURS = int(os.environ.get("DIGEST_WINDOW_HOURS", "12"))
ALIVE_PATH = Path("/tmp/.worker_alive")


# ── Jobs ──────────────────────────────────────────────────────────────────────

def job_fetch_all():
    db = get_session()
    try:
        fetcher.fetch_all_feeds(db)
    except Exception as exc:
        log.error("fetch_all_feeds error: %s", exc, exc_info=True)
    finally:
        db.close()
    # Pre-fetch article content in background after feeds are updated
    job_prefetch_content()


def job_prefetch_content():
    db = get_session()
    try:
        content_prefetch.prefetch_recent(db)
    except Exception as exc:
        log.error("prefetch_content error: %s", exc, exc_info=True)
    finally:
        db.close()


def job_run_digest():
    db = get_session()
    try:
        _run_digest(db)
    except Exception as exc:
        log.error("run_digest error: %s", exc, exc_info=True)
    finally:
        db.close()


def job_check_trigger():
    db = get_session()
    try:
        setting = db.get(Setting, "pending_digest_trigger")
        if setting and setting.value == "1":
            setting.value = "0"
            db.commit()
            log.info("Manual trigger detected — running digest now.")
            _run_digest(db)
    except Exception as exc:
        log.error("check_trigger error: %s", exc, exc_info=True)
    finally:
        db.close()


def job_cleanup():
    db = get_session()
    try:
        cutoff = datetime.utcnow() - timedelta(days=7)
        deleted = (
            db.query(Article)
            .filter(Article.cluster_id == None, Article.fetched_at < cutoff)
            .delete(synchronize_session=False)
        )
        run_cutoff = datetime.utcnow() - timedelta(days=30)
        deleted_runs = (
            db.query(DigestRun)
            .filter(DigestRun.started_at < run_cutoff)
            .delete(synchronize_session=False)
        )
        db.commit()
        log.info("Cleanup: %d orphan articles, %d old runs deleted.", deleted, deleted_runs)
    except Exception as exc:
        log.error("Cleanup error: %s", exc, exc_info=True)
    finally:
        db.close()


def job_alive_marker():
    ALIVE_PATH.touch()


# ── Digest pipeline ───────────────────────────────────────────────────────────

def _run_digest(db):
    now = datetime.utcnow()
    window_start = now - timedelta(hours=DIGEST_WINDOW_HOURS)

    run = DigestRun(window_start=window_start, window_end=now, status="running")
    db.add(run)
    db.commit()
    log.info("Digest run #%d started. Window: %s → %s", run.id, window_start, now)

    try:
        # Diagnostic: how many total unclustered articles exist?
        total_unclustered = (
            db.query(Article)
            .join(Feed)
            .filter(Article.cluster_id == None, Feed.active == True)
            .count()
        )
        log.info("Total unclustered articles in DB: %d", total_unclustered)

        # Filter by fetched_at (when we collected it), NOT published_at.
        # published_at from RSS feeds can be days/weeks old and would miss the window.
        articles = (
            db.query(Article)
            .join(Feed)
            .options(joinedload(Article.feed))
            .filter(
                Article.cluster_id == None,
                Article.fetched_at >= window_start,
                Feed.active == True,
            )
            .all()
        )

        # Fallback: if nothing in the fetch window, grab ALL unclustered articles
        # (useful on first run when all articles were fetched before any digest ran)
        if not articles and total_unclustered > 0:
            log.info(
                "No articles fetched in window but %d unclustered exist — "
                "running digest on all unclustered articles.",
                total_unclustered,
            )
            articles = (
                db.query(Article)
                .join(Feed)
                .options(joinedload(Article.feed))
                .filter(Article.cluster_id == None, Feed.active == True)
                .order_by(Article.published_at.desc())
                .limit(80)   # 2 chunks × 40 — conserva cota da IA
                .all()
            )

        if not articles:
            log.info("No articles to digest — done (empty).")
            run.status = "done"
            run.finished_at = datetime.utcnow()
            run.articles_processed = 0
            run.clusters_created = 0
            db.commit()
            return

        log.info("Clustering %d articles…", len(articles))
        cluster_defs = clusterer.cluster_articles(articles)

        id_to_article = {a.id: a for a in articles}
        created = 0

        for cdef in cluster_defs:
            label = cdef["label"]
            ids = cdef["article_ids"]
            cluster_articles_list = [id_to_article[i] for i in ids if i in id_to_article]
            if not cluster_articles_list:
                continue

            summary = summarizer.summarize_cluster(label, cluster_articles_list)

            cluster = Cluster(
                digest_run_id=run.id,
                label=label,
                summary=summary,
                article_count=len(cluster_articles_list),
            )
            db.add(cluster)
            db.flush()

            for a in cluster_articles_list:
                a.cluster_id = cluster.id

            db.commit()
            created += 1
            log.info("Cluster '%s' — %d articles.", label, len(cluster_articles_list))

        run.status = "done"
        run.finished_at = datetime.utcnow()
        run.articles_processed = len(articles)
        run.clusters_created = created
        db.commit()
        log.info("Digest run #%d done: %d clusters from %d articles.", run.id, created, len(articles))

    except Exception as exc:
        run.status = "error"
        run.error_msg = str(exc)
        run.finished_at = datetime.utcnow()
        db.commit()
        raise


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    log.info("Starting berga-news worker…")
    init_db()

    scheduler = BackgroundScheduler(timezone="America/Sao_Paulo")

    scheduler.add_job(
        job_fetch_all, "interval",
        minutes=FETCH_INTERVAL_MINUTES,
        id="fetch_all",
        max_instances=1,
        misfire_grace_time=300,
    )
    scheduler.add_job(
        job_run_digest, "cron",
        hour=7, minute=0,
        id="digest_morning",
        max_instances=1,
    )
    scheduler.add_job(
        job_run_digest, "cron",
        hour=18, minute=0,
        id="digest_evening",
        max_instances=1,
    )
    scheduler.add_job(
        job_check_trigger, "interval",
        seconds=60,
        id="check_trigger",
        max_instances=1,
    )
    scheduler.add_job(
        job_cleanup, "cron",
        hour=3, minute=0,
        id="cleanup",
    )
    scheduler.add_job(
        job_alive_marker, "interval",
        minutes=1,
        id="alive",
    )

    scheduler.start()
    job_alive_marker()
    log.info(
        "Scheduler running. Fetch every %d min. Digests at 07:00 and 18:00 SP.",
        FETCH_INTERVAL_MINUTES,
    )

    def _shutdown(signum, frame):
        log.info("Shutdown signal received.")
        scheduler.shutdown(wait=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    # Run initial fetch on startup
    log.info("Running initial feed fetch…")
    job_fetch_all()

    while True:
        time.sleep(60)


if __name__ == "__main__":
    main()
