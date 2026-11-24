"""Verify BBLL DASH recovery with a local HTTP range server and real mpv."""
import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid


class IPC:
    def __init__(self, name):
        self.path = r"\\.\pipe" + "\\" + name
        self.number = 0

    def __enter__(self):
        for _ in range(100):
            try:
                self.pipe = open(self.path, "r+b", buffering=0)
                self.reader = self.pipe.read
                return self
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("mpv IPC did not start")

    def __exit__(self, *_):
        self.pipe.close()

    def call(self, *command):
        self.number += 1
        payload = json.dumps({"command": command, "request_id": self.number})
        self.pipe.write((payload + "\n").encode())
        while True:
            line = bytearray()
            while not line.endswith(b"\n"):
                byte = self.reader(1)
                if not byte:
                    raise RuntimeError("mpv closed IPC")
                line += byte
            reply = json.loads(line)
            if reply.get("request_id") == self.number:
                return reply.get("data") if reply["error"] == "success" else None


def until(check, label, timeout=16):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.15)
    raise AssertionError(label)


PLUGIN = Path(__file__).resolve().parents[1] / "portable_config/scripts/newbv"
VIDEO_URL = "https://www.bilibili.com/video/BV1GJ411x7h7?p=1"
NEXT_URL = "https://www.bilibili.com/video/BV1GJ411x7h7?p=2"


def fixtures(folder, ffmpeg, ffprobe):
    video_path = folder / "video.mp4"
    audio_path = folder / "audio.m4a"
    args = [ffmpeg, "-loglevel", "error", "-y", "-f", "lavfi"]
    subprocess.run([*args, "-i", "testsrc2=s=320x180:r=24", "-c:v", "libx264",
                    "-g", "24", "-t", "32", "-movflags", "+faststart", video_path], check=True)
    subprocess.run([*args, "-i", "sine=frequency=440", "-c:a", "aac", "-t", "32",
                    "-movflags", "+faststart", audio_path], check=True)
    packets = json.loads(subprocess.check_output([ffprobe, "-v", "error", "-show_entries",
                         "packet=pos,pts_time", "-of", "json", video_path]))["packets"]
    cutoff = min(int(packet["pos"]) for packet in packets if float(packet["pts_time"]) >= 7)
    return video_path.read_bytes(), audio_path.read_bytes(), cutoff


@contextmanager
def serve(video, audio, cutoff, fault):
    release = threading.Event()
    switched = threading.Event()
    requests = []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def do_GET(self):
            requests.append(self.path)
            primary = self.path == "/primary.mp4"
            if self.path == "/final.mp4":
                switched.set()
            if self.path == "/backup.mp4" or self.path.startswith("/invalid") or (primary and fault == "video-error"):
                self.send_error(503)
                return
            data = audio if self.path == "/audio.m4a" else video
            requested = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
            start = int(requested[1]) if requested else 0
            end = min(int(requested[2]), len(data) - 1) if requested and requested[2] else len(data) - 1
            if start > end:
                self.send_error(416)
                return
            self.send_response(206 if requested else 200)
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Content-Type", "audio/mp4" if data is audio else "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            if requested:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            self.end_headers()
            stop = min(end + 1, cutoff) if primary else end + 1
            try:
                self.wfile.write(data[start:stop])
                if stop <= end:
                    release.wait(45)
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", switched, requests
    finally:
        release.set()
        server.shutdown()
        server.server_close()
        thread.join()


def stub_resolver(plugin, origin, fault):
    def edl(video):
        tracks = [
            ("video", "h264", "High quality", video, True),
            ("audio", "aac", "AAC default", "audio.m4a", True),
            ("audio", "aac", "AAC selected", "audio.m4a", False),
        ]
        entries = []
        for media_type, codec, title, file, default in tracks:
            url = f"{origin}/{file}"
            entry = f"!new_stream;!no_clip;!delay_open,media_type={media_type},codec={codec}"
            entry += f";!track_meta,title={title}" + (",flags=default" if default else "")
            entries.append(f"{entry};%{len(url)}%{url},length=32")
        return "edl://" + ";".join(entries)

    primary = origin + "/invalid.mp4" if fault == "open-error" else edl("primary.mp4")
    backup = edl("backup.mp4")
    data = dict(video=primary, backupVideo=backup, backupVideos=[backup, edl("final.mp4")], defaultVid=1, defaultAid=1,
                tracks=[dict(id=1, quality=120, codec="h264", title="High quality")])
    if fault == "exhausted":
        urls = [f"{origin}/invalid{index}.mp4" for index in range(4)]
        data.update(video=urls[0], backupVideo=urls[1], backupVideos=urls[1:])
    (plugin / "resolve.ps1").write_text(
        "param($Action,$Quality,$Query,$LiveQuality,$PreferredCodec,$PreferredAudio)\n"
        + "'" + json.dumps(data) + "'\n", encoding="ascii")


def verify(mpv, folder, media, fault):
    test_root = folder / fault
    test_root.mkdir()
    plugin = test_root / "newbv"
    shutil.copytree(PLUGIN, plugin)
    (plugin / "history.lua").write_text("return function() return {set=function() end} end", encoding="ascii")
    env = dict(os.environ, LOCALAPPDATA=str(test_root))
    pipe = "bbll-recovery-" + uuid.uuid4().hex
    with serve(*media, fault) as (origin, switched, requests):
        stub_resolver(plugin, origin, fault)
        process = subprocess.Popen([mpv, "--no-config", "--load-scripts=no", f"--script={plugin}",
            "--script-opts=newbv-autobrowse=no", "--idle=yes", "--vo=null", "--ao=null", "--no-ytdl",
            "--cache=yes", "--demuxer-readahead-secs=1", "--cache-pause-wait=0.3",
            "--input-ipc-server=" + pipe, "--log-file=" + str(test_root / "mpv.log")],
            env=env, creationflags=subprocess.CREATE_NO_WINDOW, stdout=subprocess.DEVNULL)
        try:
            with IPC(pipe) as ipc:
                ipc.call("loadfile", VIDEO_URL, "replace")

                def get(name):
                    return ipc.call("get_property", name)

                if fault == "exhausted":
                    until(lambda: len(requests) >= 4 and get("idle-active"), "Failed lines kept retrying")
                    assert list(dict.fromkeys(requests)) == [f"/invalid{index}.mp4" for index in range(4)], requests
                    log = (test_root / "mpv.log").read_text(encoding="utf-8", errors="replace")
                    assert log.count("Run command: playlist-play-index,") == 3
                    print("exhausted: tried each of the four CDN routes once")
                    return

                ipc.call("loadfile", NEXT_URL, "append")
                if fault == "stall":
                    until(lambda: (get("time-pos") or 0) > 1, "Initial audio clock did not start")
                    assert get("video-out-params/pixelformat")
                    ipc.call("set_property", "aid", 2)

                    def stopped():
                        position = get("time-pos")
                        time.sleep(0.35)
                        return position and position == get("time-pos")

                    until(stopped, "Primary stream did not stall")
                    resume = get("time-pos")
                    ipc.call("set_property", "pause", True)
                    assert not switched.wait(9), "Intentional pause restarted playback"
                    ipc.call("set_property", "pause", False)
                else:
                    resume = 0

                assert switched.wait(18), "mpv never requested the backup video"

                def playing_position():
                    if get("video-out-params/pixelformat") and get("audio-out-params"):
                        return get("time-pos")

                first_position = until(playing_position, "Backup did not decode both video and audio")
                assert first_position >= resume - 0.2, "Backup did not resume near the interruption"
                target = resume + 2
                until(lambda: (playing_position() or 0) > target, "Backup playback did not advance")
                assert [entry["filename"] for entry in get("playlist")] == [VIDEO_URL, NEXT_URL]
                assert get("playlist-playing-pos") == 0
                assert get("aid") == (2 if fault == "stall" else 1)
                assert get("vid") == 1
                assert requests.index("/backup.mp4") < requests.index("/final.mp4")
        finally:
            process.terminate()
            process.wait(timeout=10)
        log = (test_root / "mpv.log").read_text(encoding="utf-8", errors="replace")
        assert log.count("Run command: playlist-play-index,") == 2
        print(f"{fault}: third CDN resumed video and audio at {first_position:.2f}s; queue and track choice preserved")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mpv", type=Path, required=True)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="bbll-recovery-") as temporary:
        root = Path(temporary)
        media = fixtures(root, options.ffmpeg, options.ffprobe)
        for fault in ("exhausted", "stall", "video-error", "open-error"):
            verify(options.mpv.resolve(), root, media, fault)
