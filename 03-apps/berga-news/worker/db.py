"""
Database models and session factory (worker copy — identical to api/db.py).
"""
import os
from datetime import datetime

from sqlalchemy import (
    Boolean, Column, DateTime, ForeignKey, Integer, Text, create_engine,
    text,
)
from sqlalchemy.orm import DeclarativeBase, Session, relationship, sessionmaker

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://berganews:changeme@berganews-db:5432/berganews",
)

engine = create_engine(DATABASE_URL, pool_pre_ping=True, pool_size=3)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username = Column(Text, unique=True, nullable=False)
    password_hash = Column(Text, nullable=False)
    email = Column(Text)
    role = Column(Text, nullable=False, default="user")
    created_at = Column(DateTime, default=datetime.utcnow)


class UserSession(Base):
    __tablename__ = "sessions"
    id = Column(Text, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    expires_at = Column(DateTime, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)


class Feed(Base):
    __tablename__ = "feeds"
    id = Column(Integer, primary_key=True)
    owner_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=True)
    url = Column(Text, nullable=False)
    title = Column(Text)
    site_url = Column(Text)
    category = Column(Text)
    active = Column(Boolean, default=True)
    last_fetched_at = Column(DateTime)
    last_fetch_status = Column(Text)
    last_etag = Column(Text)
    last_modified = Column(Text)
    created_at = Column(DateTime, default=datetime.utcnow)


class Article(Base):
    __tablename__ = "articles"
    id = Column(Integer, primary_key=True)
    feed_id = Column(Integer, ForeignKey("feeds.id", ondelete="CASCADE"), nullable=False)
    guid = Column(Text, nullable=False)
    title = Column(Text, nullable=False)
    description = Column(Text)
    url = Column(Text, nullable=False)
    author = Column(Text)
    published_at = Column(DateTime)
    fetched_at = Column(DateTime, default=datetime.utcnow)
    cluster_id = Column(Integer, ForeignKey("clusters.id", ondelete="SET NULL"), nullable=True)


class DigestRun(Base):
    __tablename__ = "digest_runs"
    id = Column(Integer, primary_key=True)
    window_start = Column(DateTime, nullable=False)
    window_end = Column(DateTime, nullable=False)
    started_at = Column(DateTime, default=datetime.utcnow)
    finished_at = Column(DateTime)
    articles_processed = Column(Integer, default=0)
    clusters_created = Column(Integer, default=0)
    status = Column(Text, default="running")
    error_msg = Column(Text)


class Cluster(Base):
    __tablename__ = "clusters"
    id = Column(Integer, primary_key=True)
    digest_run_id = Column(Integer, ForeignKey("digest_runs.id", ondelete="CASCADE"), nullable=False)
    label = Column(Text, nullable=False)
    summary = Column(Text)
    article_count = Column(Integer, default=0)
    created_at = Column(DateTime, default=datetime.utcnow)


class ArticleContent(Base):
    __tablename__ = "article_contents"
    article_id = Column(Integer, ForeignKey("articles.id", ondelete="CASCADE"), primary_key=True)
    html = Column(Text, nullable=False)
    fetch_error = Column(Text)
    fetched_at = Column(DateTime, default=datetime.utcnow)


class ArticleRead(Base):
    __tablename__ = "article_reads"
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    article_id = Column(Integer, ForeignKey("articles.id", ondelete="CASCADE"), primary_key=True)
    read_at = Column(DateTime, default=datetime.utcnow)


class Setting(Base):
    __tablename__ = "settings"
    key = Column(Text, primary_key=True)
    value = Column(Text)


def init_db():
    Base.metadata.create_all(engine)
    with SessionLocal() as db:
        db.execute(text(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_feeds_unique "
            "ON feeds (COALESCE(owner_id, -1), url)"
        ))
        db.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_articles_published ON articles (published_at DESC)"
        ))
        db.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_articles_cluster ON articles (cluster_id)"
        ))
        db.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_articles_feed ON articles (feed_id)"
        ))
        db.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_article_reads_user ON article_reads (user_id)"
        ))
        db.commit()


def get_session() -> Session:
    return SessionLocal()
