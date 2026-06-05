import os
import json
import subprocess
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Tokens de idioma considerados PT-BR (qualquer um basta para detectar a legenda).
# 'pb'/'pob' = códigos do Bazarr para Brazilian Portuguese.
PT_LANG_TOKENS = {'pt-br', 'pt_br', 'ptbr', 'pt', 'por', 'pb', 'pob', 'bra', 'portuguese'}


def _is_pt_subtitle_name(filename: str, base_name: str) -> bool:
    """
    Verifica se `filename` é uma legenda PT-BR do vídeo `base_name`.

    Robusto a caixa e a qualificadores que o Bazarr insere no nome, como
    .hi (hearing impaired), .sdh e .forced. Exemplos que casam:
      base.pt-BR.srt | base.pt-BR.hi.srt | base.pb.srt | base.por.forced.srt
    E que NÃO casam: base.en.srt | base.hi.srt (hindi) | base.mkv
    """
    if not filename.startswith(base_name):
        return False
    suffix = filename[len(base_name):].lower()
    if not suffix.endswith('.srt'):
        return False
    # tokens entre o nome-base e ".srt" — ex.: ".pt-br.hi.srt" -> ["pt-br", "hi"]
    tokens = suffix[:-4].strip('.').split('.')
    return any(t in PT_LANG_TOKENS for t in tokens)


def find_pt_subtitle(filepath: str) -> str | None:
    """Retorna o caminho da legenda externa PT-BR do vídeo, ou None."""
    base_name = os.path.basename(os.path.splitext(filepath)[0])
    base_dir = os.path.dirname(filepath)
    try:
        for f in sorted(os.listdir(base_dir)):
            if _is_pt_subtitle_name(f, base_name):
                return os.path.join(base_dir, f)
    except OSError:
        pass
    return None


def has_pt_subtitle(filepath: str) -> bool:
    """Detecção (case-insensitive) de legenda externa PT-BR, incluindo .hi/.sdh/.forced."""
    return find_pt_subtitle(filepath) is not None


def get_media_info(filepath):
    """
    Uses ffprobe to get media information (streams, duration, etc.)
    """
    try:
        cmd = [
            'ffprobe',
            '-v', 'quiet',
            '-print_format', 'json',
            '-show_format',
            '-show_streams',
            filepath
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        logger.error(f"Error probing file {filepath}: {e}")
        return None

def extract_subtitle(filepath, stream_index, output_path):
    """
    Extracts a subtitle stream to a file.
    """
    try:
        cmd = [
            'ffmpeg',
            '-y',
            '-i', filepath,
            '-map', f'0:{stream_index}',
            output_path
        ]
        subprocess.run(cmd, check=True, capture_output=True)
        logger.info(f"Extracted subtitle stream {stream_index} to {output_path}")
        return True
    except subprocess.CalledProcessError as e:
        logger.error(f"Error extracting subtitle: {e}")
        return False

def check_existing_subtitle(filepath, lang_code='por'):
    """
    Checks if a subtitle file with the given language code exists (case-insensitive).
    """
    base_path = os.path.splitext(filepath)[0]
    directory = os.path.dirname(base_path)
    filename = os.path.basename(base_path)
    
    # Extensions to check
    target_suffixes = [
        f".{lang_code}.srt",
        ".pt-br.srt",
        ".pt.srt",
        ".por.srt"
    ]
    
    try:
        # List all files in the directory
        files = os.listdir(directory)
        for f in files:
            # Check if file starts with the video filename (case-insensitive check for safety?)
            # Usually video and sub have same case basename, but let's be strict on basename, loose on suffix
            if f.startswith(filename):
                # Check if the remainder matches one of our suffixes (case-insensitive)
                suffix = f[len(filename):].lower()
                if suffix in target_suffixes:
                    return True
    except Exception as e:
        logger.error(f"Error checking existing subtitles: {e}")
        return False
    
    return False

def save_subtitle(content, output_path):
    """
    Saves subtitle content to a file with UTF-8 encoding.
    """
    try:
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(content)
        logger.info(f"Saved subtitle to {output_path}")
        return True
    except Exception as e:
        logger.error(f"Error saving subtitle to {output_path}: {e}")
        return False
