import os
import subprocess
import json
import logging
from .stats_manager import StatsManager

logger = logging.getLogger(__name__)

# Configuração de Qualidade NVENC (GTX 1060)
NVENC_QUALITY = "28"
PRESET = "p4"

class Processor:
    def __init__(self):
        self.stats = StatsManager()

    def get_codec(self, filepath):
        """Usa ffprobe para descobrir se o vídeo já é HEVC."""
        try:
            cmd = [
                'ffprobe', 
                '-v', 'error', 
                '-select_streams', 'v:0', 
                '-show_entries', 'stream=codec_name', 
                '-of', 'json', 
                filepath
            ]
            resultado = subprocess.check_output(cmd).decode('utf-8')
            dados = json.loads(resultado)
            return dados['streams'][0]['codec_name']
        except Exception as e:
            logger.error(f"Erro ao ler metadados de {filepath}: {e}")
            return None

    def process_file(self, filepath):
        filename = os.path.basename(filepath)
        logger.info(f"🔎 Analyzing file: {filename}")
        
        codec = self.get_codec(filepath)
        
        if codec == 'hevc':
            logger.info(f"⏭️  Skipping (already HEVC): {filename}")
            return

        if not codec:
            logger.warning(f"⚠️  Could not determine codec for: {filename}")
            return

        logger.info(f"🎬 Codec found: {codec}. Starting conversion for {filename}")
        self._convert_video(filepath)

    def get_duration(self, filepath):
        """Obtém a duração do vídeo em segundos usando ffprobe."""
        try:
            cmd = [
                'ffprobe', 
                '-v', 'error', 
                '-show_entries', 'format=duration', 
                '-of', 'default=noprint_wrappers=1:nokey=1', 
                filepath
            ]
            result = subprocess.check_output(cmd).decode('utf-8').strip()
            return float(result)
        except Exception as e:
            logger.error(f"Erro ao obter duração de {filepath}: {e}")
            return 0

    def _convert_video(self, input_file):
        """Converte o vídeo usando NVENC com barra de progresso."""
        filename = os.path.basename(input_file)
        # Use dedicated temp directory
        temp_dir = "/app/temp"
        if not os.path.exists(temp_dir):
            os.makedirs(temp_dir, exist_ok=True)
            
        temp_file = os.path.join(temp_dir, filename + ".temp.mkv")
        
        duration = self.get_duration(input_file)
        
        cmd = [
            'ffmpeg',
            '-y',
            '-vsync', '0',
            '-hwaccel', 'cuda',
            '-hwaccel_output_format', 'cuda',
            '-i', input_file,
            # -map preserva TODAS as trilhas: vídeo principal + TODOS os áudios + legendas.
            # Sem isto, o ffmpeg mantinha só 1 faixa de áudio (a default) e descartava o
            # resto — transformando multiáudio (ex.: ENG+ITA) em mono-áudio no Jellyfin.
            '-map', '0:v:0',
            '-map', '0:a',
            '-map', '0:s?',
            '-c:v', 'hevc_nvenc',
            '-preset', PRESET,
            '-cq', NVENC_QUALITY,
            '-c:a', 'copy',
            '-c:s', 'copy',
            temp_file
        ]
        
        cmd_str = " ".join(cmd)
        logger.info(f"🚀 Starting NVENC conversion for {filename}...")
        logger.debug(f"Command: {cmd_str}")

        try:
            process = subprocess.Popen(
                cmd,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                encoding='utf-8' # Ensure UTF-8 decoding
            )

            last_percentage = 0
            
            # Read stderr line by line
            for line in process.stderr:
                if "time=" in line:
                    try:
                        # Parse time=HH:MM:SS.mm
                        time_str = line.split("time=")[1].split()[0]
                        h, m, s = time_str.split(':')
                        current_seconds = float(h) * 3600 + float(m) * 60 + float(s)
                        
                        if duration > 0:
                            percentage = int((current_seconds / duration) * 100)
                            
                            # Update log every 10%
                            if percentage >= last_percentage + 10:
                                blocks = int(percentage / 10)
                                bar = "█" * blocks + "░" * (10 - blocks)
                                logger.info(f"⏳ Progress: [{bar}] {percentage}%")
                                last_percentage = percentage
                    except:
                        pass # Ignore parsing errors
            
            process.wait()

            if process.returncode != 0:
                raise subprocess.CalledProcessError(process.returncode, cmd)

            # PROTEÇÃO ANTI-TRUNCAMENTO: nunca substituir o original por um vídeo de
            # duração menor (arquivo parcial em import, falha de GPU no meio, etc.).
            nova_duracao = self.get_duration(temp_file)
            if duration > 0 and nova_duracao > 0 and nova_duracao < duration * 0.98:
                logger.error(
                    f"❌ Resultado mais curto que o original ({nova_duracao:.0f}s < {duration:.0f}s) — "
                    f"possível corte/arquivo parcial. Mantendo o original e descartando: {filename}"
                )
                os.remove(temp_file)
                return

            # Verification and Move
            tamanho_original = os.path.getsize(input_file)
            tamanho_novo = os.path.getsize(temp_file)
            
            if tamanho_novo < tamanho_original:
                economia = (1 - (tamanho_novo / tamanho_original)) * 100
                savings_gb = (tamanho_original - tamanho_novo) / (1024**3)
                
                logger.info(f"✅ Success! {filename}")
                logger.info(f"   📉 Original: {tamanho_original / (1024**3):.2f} GB")
                logger.info(f"   📉 New:      {tamanho_novo / (1024**3):.2f} GB")
                logger.info(f"   💰 Saved:    {savings_gb:.2f} GB ({economia:.2f}%)")
                logger.info(f"   🔄 Moving file back to library...")
                
                # Cross-device move
                import shutil
                os.remove(input_file)
                shutil.move(temp_file, input_file)
                
                self.stats.update_stat(input_file, tamanho_original, tamanho_novo)
            else:
                logger.warning(f"⚠️  Conversion result is larger or same size. Keeping original.")
                logger.info(f"   📉 Original: {tamanho_original} bytes")
                logger.info(f"   📈 New:      {tamanho_novo} bytes")
                os.remove(temp_file)

        except subprocess.CalledProcessError as e:
            logger.error(f"❌ FFmpeg failed for {filename}")
            if os.path.exists(temp_file):
                os.remove(temp_file)
        except Exception as e:
            logger.error(f"❌ General error converting {filename}: {e}")
            if os.path.exists(temp_file):
                 try:
                    os.remove(temp_file)
                 except:
                    pass
