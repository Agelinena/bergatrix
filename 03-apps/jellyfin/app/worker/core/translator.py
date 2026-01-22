import time
import re
import logging
import google.generativeai as genai
from .utils import save_subtitle

logger = logging.getLogger(__name__)

class Translator:
    def __init__(self, api_key):
        genai.configure(api_key=api_key)
        self.models = ['gemini-2.5-flash', 'gemini-1.5-pro', 'gemini-2.0-flash-exp', 'gemini-1.5-flash' ]
        self.current_model_index = 0

    def get_model(self):
        model_name = self.models[self.current_model_index]
        return genai.GenerativeModel(model_name), model_name

    def rotate_model(self):
        self.current_model_index = (self.current_model_index + 1) % len(self.models)
        return self.models[self.current_model_index]

    def extract_timestamps(self, srt_content):
        """
        Extracts timestamps from SRT content.
        Returns a list of (index, timestamp_line, start_seconds, end_seconds).
        """
        timestamps = []
        pattern = re.compile(r'(\d+)\s*\n(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})')
        matches = pattern.findall(srt_content)
        
        for index, start_str, end_str in matches:
            start_sec = self.parse_timestamp(start_str)
            end_sec = self.parse_timestamp(end_str)
            timestamps.append({
                'index': index,
                'timestamp_line': f"{start_str} --> {end_str}",
                'start': start_sec,
                'end': end_sec
            })
        return timestamps

    def parse_timestamp(self, timestamp_str):
        """Converts HH:MM:SS,mmm to seconds."""
        h, m, s_ms = timestamp_str.split(':')
        s, ms = s_ms.split(',')
        return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0

    def translate_with_retry(self, text_content):
        """
        Translates content with robust retry and model fallback logic.
        """
        prompt = """
Você é um tradutor profissional de legendas (SRT). Traduza o conteúdo abaixo para Português do Brasil (pt-br). 
Adapte gírias e expressões para o contexto brasileiro. 
NÃO altere a quantidade de linhas de diálogo. 
Retorne apenas o texto traduzido no formato SRT.
"""
        full_prompt = f"{prompt}\n\n{text_content}"
        
        while True:
            model, model_name = self.get_model()
            logger.info(f"Attempting translation with model: {model_name}")
            
            try:
                response = model.generate_content(full_prompt)
                return response.text
            except Exception as e:
                error_str = str(e)
                # Handle Quota (429) AND Not Found (404) by rotating
                if "429" in error_str or "quota" in error_str.lower() or "404" in error_str:
                    logger.warning(f"Error {error_str} on {model_name}. Rotating model...")
                    
                    # Check if we completed a full cycle (back to start)
                    next_model = self.rotate_model()
                    if next_model == self.models[0]:
                        logger.warning("All models exhausted. Waiting 5 minutes before retrying...")
                        time.sleep(300)
                    else:
                        # Small delay before switching
                        time.sleep(2)
                else:
                    logger.error(f"Non-recoverable error on {model_name}: {e}")
                    # For other errors, we might want to retry or fail. 
                    # If it's a server error (500), maybe retry?
                    # For now, let's wait a bit and retry same model once? 
                    # Or just return None to skip chunk (risky).
                    # Let's try to rotate for ANY error for robustness, but log it.
                    logger.warning(f"Unknown error on {model_name}, rotating anyway...")
                    self.rotate_model()
                    time.sleep(5)

    def parse_translation(self, raw_translation):
        """
        Parses the raw translation from Gemini using the loose parsing regex.
        """
        pattern = re.compile(r'(\d+)\s*\n.*?\n(.*?)(?=\n\s*\d+\s*\n|\Z)', re.DOTALL)
        matches = pattern.findall(raw_translation)
        return {index: text.strip() for index, text in matches}

    def merge_and_save(self, original_srt_path, translated_text_map, output_path):
        """
        Merges original timestamps with translated text.
        """
        try:
            with open(original_srt_path, 'r', encoding='utf-8') as f:
                original_content = f.read()

            # Re-extract simply for merging
            pattern = re.compile(r'(\d+)\s*\n(\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3})')
            matches = pattern.findall(original_content)
            
            # Validation: Check for line count mismatch
            if len(matches) != len(translated_text_map):
                logger.warning(f"Line count mismatch! Original: {len(matches)}, Translated: {len(translated_text_map)}. Some subtitles may be missing or empty.")

            final_srt = []
            for index, timecode in matches:
                text = translated_text_map.get(index, "")
                final_srt.append(f"{index}\n{timecode}\n{text}\n")
            
            final_content = "\n".join(final_srt)
            return save_subtitle(final_content, output_path)

        except Exception as e:
            logger.error(f"Error merging subtitles: {e}")
            return False

    def split_content_by_time(self, content, chunk_duration=900): # 15 minutes
        """
        Splits content into chunks based on time duration.
        """
        timestamps = self.extract_timestamps(content)
        if not timestamps:
            return []

        chunks = []
        current_chunk = []
        chunk_start_time = timestamps[0]['start']
        
        # We need to map indices to the actual text block
        # Let's parse the full content into a map first
        blocks = re.split(r'\n\s*\n', content.strip())
        text_map = {}
        for block in blocks:
            parts = block.strip().split('\n')
            if len(parts) >= 3:
                idx = parts[0].strip()
                text_map[idx] = block

        for ts in timestamps:
            if ts['start'] - chunk_start_time > chunk_duration:
                if current_chunk:
                    chunks.append(current_chunk)
                current_chunk = []
                chunk_start_time = ts['start']
            
            idx = ts['index']
            if idx in text_map:
                current_chunk.append(text_map[idx])

        if current_chunk:
            chunks.append(current_chunk)
            
        return ["\n\n".join(chunk) for chunk in chunks]

    def process(self, source_srt_path, output_path):
        """
        Main translation workflow: Chunk -> Translate -> Merge.
        """
        logger.info(f"Starting translation for {source_srt_path}")
        
        try:
            with open(source_srt_path, 'r', encoding='utf-8') as f:
                content = f.read()
            
            # 1. Split into 15-minute chunks
            chunks = self.split_content_by_time(content)
            logger.info(f"Split content into {len(chunks)} chunks (approx 15 mins each).")
            
            full_translated_map = {}
            
            for i, chunk in enumerate(chunks, 1):
                logger.info(f"Translating chunk {i}/{len(chunks)}")
                
                # 2. Translate Chunk with Retry
                raw_translation = self.translate_with_retry(chunk)
                
                if raw_translation:
                    # 3. Parse Chunk
                    chunk_map = self.parse_translation(raw_translation)
                    full_translated_map.update(chunk_map)
                else:
                    logger.error(f"Failed to translate chunk {i}. Skipping.")

            # 4. Merge & Save
            return self.merge_and_save(source_srt_path, full_translated_map, output_path)

        except Exception as e:
            logger.error(f"Translation process failed: {e}")
            return False
