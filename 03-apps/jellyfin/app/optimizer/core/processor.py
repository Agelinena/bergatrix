import os
import subprocess
import json
import logging
import shutil
from .stats_manager import StatsManager

logger = logging.getLogger(__name__)

# Configuração de Qualidade NVENC (GTX 1060)
NVENC_QUALITY = "28"
PRESET = "p6"
HEVC_TUNE = "hq"
HEVC_PROFILE = "main10"
PIX_FMT = "p010le"
TEMP_DIR = "/app/temp"
REQUIRES_REDOWNLOAD_LOG = "/app/requires_redownload.txt"

class Processor:
    def __init__(self):
        self.stats = StatsManager()
        os.makedirs(TEMP_DIR, exist_ok=True)
        # Probe NVENC capabilities once per process
        self._nvenc_caps = self._probe_nvenc_capabilities()

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
            resultado = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode('utf-8')
            dados = json.loads(resultado)
            return dados['streams'][0]['codec_name']
        except Exception as e:
            logger.error(f"Erro ao ler metadados de {filepath}: {e}")
            return None

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
            result = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode('utf-8').strip()
            return float(result)
        except Exception as e:
            logger.error(f"Erro ao obter duração de {filepath}: {e}")
            return 0.0

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

        original_duration = self.get_duration(filepath)
        if original_duration <= 0:
            logger.warning(f"⚠️  Could not determine original duration for: {filename}")

        temp_file = os.path.join(TEMP_DIR, filename + ".temp.mkv")
        healed_file = os.path.join(TEMP_DIR, filename + ".healed.temp.mkv")

        if self._run_conversion(filepath, temp_file, original_duration):
            self._finalize_conversion(filepath, temp_file, original_duration)
            return

        logger.warning(f"⚠️  Primary conversion failed for {filename}. Attempting heal step...")
        self._cleanup_temp_files(temp_file)

        if not self._heal_file(filepath, healed_file):
            self._fallback(filepath, filename)
            return

        logger.info(f"✅ Heal succeeded for {filename}. Retrying conversion using healed file.")
        if self._run_conversion(healed_file, temp_file, original_duration):
            self._finalize_conversion(filepath, temp_file, original_duration)
            self._cleanup_temp_files(healed_file)
            return

        logger.warning(f"⚠️  Secondary conversion failed for {filename}. Falling back.")
        self._cleanup_temp_files(temp_file, healed_file)
        self._fallback(filepath, filename)

    def _run_conversion(self, input_file, output_file, original_duration):
        filename = os.path.basename(input_file)
        # Build primary NVENC 10-bit command (adapt flags based on probed capabilities)
        caps = self._nvenc_caps or {}
        supports_10bit = caps.get('supports_10bit', False)
        max_bframes = caps.get('max_bframes', 0)
        primary_cmd = [
            'ffmpeg',
            '-y',
            '-err_detect', 'ignore_err',
            '-vsync', '0',
            '-i', input_file,
            '-map', '0:V:0',
            '-map', '0:a',
            '-map', '0:s?',
            '-c:v', 'hevc_nvenc',
            '-preset', PRESET,
            '-tune', HEVC_TUNE,
            '-cq', NVENC_QUALITY,
            '-spatial_aq', '1',
        ]

        # Add B-frame and b_ref_mode only if device supports B-frames
        bf_value = min(3, max_bframes) if max_bframes >= 0 else 0
        if bf_value > 0:
            primary_cmd += ['-bf', str(bf_value), '-b_ref_mode', 'middle']

        # Add 10-bit profile/pix_fmt only if supported
        if supports_10bit:
            primary_cmd += ['-profile:v', HEVC_PROFILE, '-pix_fmt', PIX_FMT]

        # Prefer explicit GPU selection
        primary_cmd += ['-gpu', '0']
        # Add audio/subtitle copy and output
        primary_cmd += ['-c:a', 'copy', '-c:s', 'copy', output_file]

        # Fallback 1: NVENC without 10-bit/profile/pix_fmt (more widely supported)
        fallback_nvenc_cmd = [c for c in primary_cmd if c not in ('-profile:v', HEVC_PROFILE, '-pix_fmt', PIX_FMT)]

        # Fallback 2: software x265 (slower but more compatible)
        software_cmd = [
            'ffmpeg',
            '-y',
            '-err_detect', 'ignore_err',
            '-vsync', '0',
            '-i', input_file,
            '-map', '0:V:0',
            '-map', '0:a',
            '-map', '0:s?',
            '-c:v', 'libx265',
            '-preset', 'slow',
            '-crf', NVENC_QUALITY,
            '-c:a', 'copy',
            '-c:s', 'copy',
            output_file
        ]

        # Try commands in order with conservative NVENC retry logic
        attempts = [('primary NVENC (10-bit)', primary_cmd), ('fallback NVENC (8-bit)', fallback_nvenc_cmd), ('software x265', software_cmd)]
        for label, cmd in attempts:
            logger.info(f"🚀 Running {label} conversion for {filename}...")
            logger.debug("Command: %s", " ".join(cmd))

            # Debug: log device nodes and environment briefly
            try:
                logger.debug("NVIDIA_VISIBLE_DEVICES=%s", os.environ.get('NVIDIA_VISIBLE_DEVICES'))
                if os.path.exists('/dev'):
                    devs = [d for d in os.listdir('/dev') if d.startswith('nvidia')]
                    logger.debug("/dev contains: %s", devs)
            except Exception:
                pass

            stderr_lines = []
            return_code = -1
            max_attempts = 2 if 'NVENC' in label.upper() else 1
            for attempt in range(1, max_attempts + 1):
                try:
                    process = subprocess.Popen(cmd, stderr=subprocess.PIPE, universal_newlines=True, encoding='utf-8')
                    last_percentage = 0
                    if process.stderr:
                        for line in process.stderr:
                            stderr_lines.append(line)
                            if "time=" in line:
                                try:
                                    time_str = line.split("time=")[1].split()[0]
                                    h, m, s = time_str.split(':')
                                    current_seconds = float(h) * 3600 + float(m) * 60 + float(s)
                                    if original_duration > 0:
                                        percentage = int((current_seconds / original_duration) * 100)
                                        if percentage >= last_percentage + 10:
                                            blocks = int(percentage / 10)
                                            bar = "█" * blocks + "░" * (10 - blocks)
                                            logger.info(f"⏳ Progress: [{bar}] {percentage}%")
                                            last_percentage = percentage
                                except Exception:
                                    pass

                    process.wait()
                    return_code = process.returncode
                except Exception as e:
                    logger.error(f"❌ FFmpeg execution failed for {filename} ({label}) attempt {attempt}: {e}")
                    return_code = -1

                if return_code == 0:
                    logger.info(f"✅ FFmpeg succeeded for {filename} ({label})")
                    return True

                excerpt = ''.join(stderr_lines[-80:]) if stderr_lines else ''
                # Retry NVENC once for device-related transient failures
                if ('NVENC' in label.upper()) and ('No capable devices found' in excerpt or 'Could not open encoder' in excerpt):
                    logger.warning(f"🔁 NVENC device error on attempt {attempt} for {filename}; retrying after 1s...")
                    import time
                    time.sleep(1)
                    continue

                # otherwise, break attempts for this command
                break

            # save stderr after attempts
            try:
                err_log = os.path.join(TEMP_DIR, f"{filename}.ffmpeg.err.log")
                try:
                    ffv = subprocess.run(['ffmpeg','-version'], capture_output=True, text=True, timeout=5)
                    ffv_text = ffv.stdout.splitlines()[0] if ffv and ffv.stdout else ''
                except Exception:
                    ffv_text = ''
                with open(err_log, 'w', encoding='utf-8', errors='ignore') as f:
                    if ffv_text:
                        f.write(f"# ffmpeg: {ffv_text}\n")
                    f.write(f"# command: {' '.join(cmd)}\n")
                    f.write("# stderr:\n")
                    f.writelines(stderr_lines)
                excerpt = ''.join(stderr_lines[-80:]) if stderr_lines else ''
                logger.error(f"❌ FFmpeg returned exit code {return_code} for {filename} ({label}). Stderr saved to: {err_log}")
                if excerpt:
                    logger.error(f"❌ Stderr excerpt:\n{excerpt}")
            except Exception:
                logger.error(f"❌ FFmpeg returned exit code {return_code} for {filename} ({label}). (stderr not saved)")

            # try next fallback
            continue

        # all attempts failed
        logger.error(f"❌ All encoding attempts failed for {filename}")
        return False

    def _heal_file(self, input_file, output_file):
        filename = os.path.basename(input_file)
        cmd = [
            'ffmpeg',
            '-y',
            '-err_detect', 'ignore_err',
            '-i', input_file,
            '-map', '0',
            '-c', 'copy',
            output_file
        ]

        logger.info(f"🛠️  Healing file container for {filename}...")
        logger.debug("Heal command: %s", " ".join(cmd))

        try:
            completed = subprocess.run(cmd, stderr=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            if completed.returncode != 0:
                # save heal stderr
                try:
                    heal_log = os.path.join(TEMP_DIR, f"{filename}.heal.err.log")
                    with open(heal_log, 'w', encoding='utf-8', errors='ignore') as f:
                        f.write(completed.stderr or '')
                    logger.error(f"❌ Heal failed for {filename} with exit code {completed.returncode}. Stderr saved to: {heal_log}")
                    if completed.stderr:
                        logger.error(f"❌ Heal stderr excerpt:\n{(completed.stderr.splitlines()[-40:])}")
                except Exception:
                    logger.error(f"❌ Heal failed for {filename} with exit code {completed.returncode}. (stderr not saved)")
                return False
            # optionally log a small stdout/stderr snippet for successful heal
            if completed.stderr:
                logger.debug(f"Heal stderr (truncated): {''.join(completed.stderr.splitlines()[-10:])}")
            return True
        except Exception as e:
            logger.error(f"❌ Heal execution failed for {filename}: {e}")
            return False

    def _probe_nvenc_capabilities(self):
        """Probe local ffmpeg hevc_nvenc encoder capabilities.

        Returns a dict with keys like 'supports_10bit' and 'max_bframes'.
        If ffmpeg or encoder info cannot be retrieved, returns empty dict.
        """
        caps = {}
        try:
            p = subprocess.run(['ffmpeg', '-hide_banner', '-h', 'encoder=hevc_nvenc'], capture_output=True, text=True, timeout=5)
            out = p.stdout or p.stderr or ''
            # Detect 10-bit support
            caps['supports_10bit'] = 'p010le' in out or 'main10' in out
            # Try to find a line mentioning "Max B-frames" or similar
            max_b = 0
            for line in out.splitlines():
                l = line.lower()
                if 'max b-frames' in l or 'max b_frames' in l or 'max_b_frames' in l:
                    # extract number
                    import re
                    m = re.search(r"(\d+)", l)
                    if m:
                        max_b = int(m.group(1))
                        break
            caps['max_bframes'] = max_b
        except Exception:
            return {}
        return caps

    def _finalize_conversion(self, original_file, temp_file, original_duration):
        filename = os.path.basename(original_file)
        if not os.path.exists(temp_file):
            logger.error(f"❌ Expected temporary file not found: {temp_file}")
            return

        new_duration = self.get_duration(temp_file)
        if original_duration > 0 and new_duration > 0:
            duration_diff = abs(new_duration - original_duration)
            if duration_diff > 2.0:
                logger.error(
                    f"❌ Duration mismatch for {filename}: original={original_duration:.2f}s, new={new_duration:.2f}s "
                    f"(diff={duration_diff:.2f}s) - discarding temp file"
                )
                self._cleanup_temp_files(temp_file)
                return

        original_size = os.path.getsize(original_file)
        new_size = os.path.getsize(temp_file)

        if new_size >= original_size:
            logger.warning(f"⚠️  Converted file is not smaller for {filename}. Keeping original.")
            logger.info(f"   📉 Original: {original_size} bytes")
            logger.info(f"   📈 New:      {new_size} bytes")
            self._cleanup_temp_files(temp_file)
            return

        savings_gb = (original_size - new_size) / (1024**3)
        economia = (1 - (new_size / original_size)) * 100
        logger.info(f"✅ Conversion successful for {filename}")
        logger.info(f"   📉 Original: {original_size / (1024**3):.2f} GB")
        logger.info(f"   📉 New:      {new_size / (1024**3):.2f} GB")
        logger.info(f"   💰 Saved:    {savings_gb:.2f} GB ({economia:.2f}%)")
        logger.info(f"   🔄 Replacing original file...")

        try:
            os.remove(original_file)
            shutil.move(temp_file, original_file)
            self.stats.update_stat(original_file, original_size, new_size)
        except Exception as e:
            logger.error(f"❌ Failed to replace original for {filename}: {e}")
            self._cleanup_temp_files(temp_file)

    def _fallback(self, original_file, filename):
        logger.error(f"🚫 File failed after healing attempts: {filename}. Keeping original.")
        try:
            with open(REQUIRES_REDOWNLOAD_LOG, 'a', encoding='utf-8') as f:
                f.write(f"{original_file}\n")
        except Exception as e:
            logger.error(f"❌ Could not write to redownload log: {e}")

    def _cleanup_temp_files(self, *files):
        for path in files:
            try:
                if path and os.path.exists(path):
                    os.remove(path)
            except Exception:
                pass
