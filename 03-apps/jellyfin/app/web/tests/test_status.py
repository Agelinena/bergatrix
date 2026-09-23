import importlib.util
import tempfile
from pathlib import Path

MAIN_PATH = Path(__file__).resolve().parents[1] / "main.py"

spec = importlib.util.spec_from_file_location("legendarr_web_main", MAIN_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def test_status_is_green_when_any_subtitle_file_exists():
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        movie = base / "movie.mkv"
        movie.write_bytes(b"x")
        (base / "movie.en.srt").write_text("1\n00:00:00,000 --> 00:00:02,000\nhello\n", encoding="utf-8")

        status = module.get_subtitle_status(str(movie), translated_paths={})

        assert status == "🟢"


def test_status_is_red_when_no_subtitle_exists():
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        movie = base / "movie.mkv"
        movie.write_bytes(b"x")

        status = module.get_subtitle_status(str(movie), translated_paths={})

        assert status == "🔴"
