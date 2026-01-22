import os
import logging
from .utils import get_media_info, check_existing_subtitle, extract_subtitle
from .translator import Translator

logger = logging.getLogger(__name__)

# Configuration
TARGET_LANGUAGES = ['por', 'pt', 'bra', 'pt-br', 'por-br', 'pob']
SOURCE_LANGUAGES = ['eng', 'en']

class Pipeline:
    def __init__(self, gemini_api_key):
        self.translator = Translator(gemini_api_key)

    def process_file(self, filepath, force=False):
        logger.info(f"Processing file: {filepath} (Force: {force})")
        
        media_info = get_media_info(filepath)
        if not media_info:
            logger.error("Could not get media info.")
            return

        # Debug: Log all found streams
        logger.info(f"Media Info Streams: {len(media_info.get('streams', []))}")
        for i, stream in enumerate(media_info.get('streams', [])):
            if stream['codec_type'] == 'subtitle':
                logger.info(f"Stream {i}: Codec={stream.get('codec_name')}, Lang={stream.get('tags', {}).get('language')}, Title={stream.get('tags', {}).get('title')}")

        if not force:
            # 1. Check Internal PT-BR subtitles
            for stream in media_info.get('streams', []):
                if stream['codec_type'] == 'subtitle':
                    tags = stream.get('tags', {})
                    lang = tags.get('language', '').lower()
                    if lang in TARGET_LANGUAGES:
                        logger.info("Internal PT-BR subtitle found. Skipping.")
                        return

            # 2. Check External PT-BR subtitles
            if check_existing_subtitle(filepath):
                logger.info("External PT-BR subtitle found. Skipping.")
                return

        base_path = os.path.splitext(filepath)[0]
        output_srt = f"{base_path}.por.srt"

        # 3. Check Internal English Subtitles (for translation)
        english_sub_stream = None
        for stream in media_info.get('streams', []):
            if stream['codec_type'] == 'subtitle':
                tags = stream.get('tags', {})
                lang = tags.get('language', '').lower()
                title = tags.get('title', '').lower()
                
                # Filter unwanted tracks
                if any(x in title for x in ['commentary', 'director', 'description', 'sdh']):
                    continue

                if lang in SOURCE_LANGUAGES:
                    if stream['codec_name'] in ['subrip', 'ass', 'webvtt', 'mov_text']: # Text formats preferred
                        english_sub_stream = stream
                        break 
        
        if english_sub_stream:
            logger.info(f"Found Internal English subtitle stream index {english_sub_stream['index']}. Extracting and translating.")
            temp_eng_srt = f"{base_path}.eng.temp.srt"
            
            if extract_subtitle(filepath, english_sub_stream['index'], temp_eng_srt):
                if self.translator.process(temp_eng_srt, output_srt):
                    logger.info("Translation successful.")
                    os.remove(temp_eng_srt)
                    return
                else:
                    logger.error("Translation failed.")
            else:
                logger.error("Failed to extract English subtitle.")

        # 4. Check External English Subtitles (for translation)
        # Assuming external english subs might be named .eng.srt or .en.srt
        for ext in ['.eng.srt', '.en.srt']:
            ext_eng_path = f"{base_path}{ext}"
            if os.path.exists(ext_eng_path):
                logger.info(f"Found External English subtitle: {ext_eng_path}. Translating.")
                if self.translator.process(ext_eng_path, output_srt):
                    logger.info("Translation successful.")
                    return
                else:
                     logger.error("Translation failed.")

        # 5. Check ANY internal subtitle (excluding commentary AND Portuguese)
        any_sub_stream = None
        for stream in media_info.get('streams', []):
            if stream['codec_type'] == 'subtitle':
                tags = stream.get('tags', {})
                title = tags.get('title', '').lower()
                lang = tags.get('language', '').lower()
                
                # Skip Portuguese (we don't want to translate PT to PT)
                if lang in TARGET_LANGUAGES:
                    continue

                if any(x in title for x in ['commentary', 'director', 'description', 'sdh']):
                    continue
                
                if stream['codec_name'] in ['subrip', 'ass', 'webvtt', 'mov_text']:
                     any_sub_stream = stream
                     break
        
        if any_sub_stream:
            logger.info(f"Found fallback subtitle stream index {any_sub_stream['index']} (Lang: {any_sub_stream.get('tags', {}).get('language', 'unknown')}). Extracting and translating.")
            temp_any_srt = f"{base_path}.any.temp.srt"
            
            if extract_subtitle(filepath, any_sub_stream['index'], temp_any_srt):
                if self.translator.process(temp_any_srt, output_srt):
                    logger.info("Translation successful.")
                    os.remove(temp_any_srt)
                    return
                else:
                    logger.error("Translation failed.")
            else:
                logger.error("Failed to extract fallback subtitle.")

        # Check for bitmap subtitles to warn user
        bitmap_subs = []
        for stream in media_info.get('streams', []):
             if stream['codec_name'] in ['hdmv_pgs_subtitle', 'dvd_subtitle']:
                 bitmap_subs.append(stream['codec_name'])
        
        if bitmap_subs:
             logger.warning(f"Found bitmap subtitles ({', '.join(set(bitmap_subs))}) which are not supported for translation. Please provide external text subtitles (SRT).")

        logger.info("No suitable subtitle found for translation.")
