#!/usr/bin/env python3
import sys
import os
import subprocess
import re
import shutil

# Ensure alass is installed
ALASS_PATH = shutil.which("alass-cli") or "/opt/homebrew/bin/alass-cli"
if not os.path.exists(ALASS_PATH):
    print("Error: alass-cli not found. Please install it with: brew install alass")
    sys.exit(1)

if len(sys.argv) < 3:
    print("Usage: python3 sync_subs.py <video.mp4> <input.srt> [output.srt]")
    sys.exit(1)

video_file = sys.argv[1]
input_srt = sys.argv[2]
output_srt = sys.argv[3] if len(sys.argv) > 3 else input_srt.replace(".srt", "_synced.srt")

if not os.path.exists(video_file) or not os.path.exists(input_srt):
    print("Error: Video or SRT file not found.")
    sys.exit(1)

print(f"Step 1: Running Alass Dynamic Sync on {input_srt}...")
temp_srt = output_srt + ".tmp.srt"
result = subprocess.run([ALASS_PATH, video_file, input_srt, temp_srt])

if result.returncode != 0:
    print("Error: Alass failed to sync the file.")
    if os.path.exists(temp_srt): 
        os.remove(temp_srt)
    sys.exit(1)

print("Step 2: Applying technical fixes (gaps, reading speed, duration)...")

# --- Technical Fix Logic ---
def parse_time(t_str):
    h, m, s_ms = t_str.split(':')
    s, ms = s_ms.split(',')
    return int(h)*3600000 + int(m)*60000 + int(s)*1000 + int(ms)

def format_time(ms):
    h = int(ms / 3600000)
    ms %= 3600000
    m = int(ms / 60000)
    ms %= 60000
    s = int(ms / 1000)
    ms %= 1000
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

def process_srt(filepath, outpath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read().strip().replace('\r\n', '\n').replace('\r', '\n')
        
    blocks = re.split(r'\n\n+', content)
    subs = []
    for block in blocks:
        lines = block.split('\n')
        if len(lines) >= 3:
            times = lines[1].split(' --> ')
            if len(times) == 2:
                try:
                    subs.append({
                        'start': parse_time(times[0]),
                        'end': parse_time(times[1]),
                        'text': '\n'.join(lines[2:])
                    })
                except:
                    pass

    for i in range(len(subs)):
        start = subs[i]['start']
        end = subs[i]['end']
        char_count = len(re.sub(r'<[^>]+>', '', subs[i]['text']).replace('\n', ' '))
        
        # 1. Truncate max duration (7s)
        if end - start > 7000: 
            end = start + 7000
            
        # 2. Stretch for min duration (0.83s) or CPS (<=20 chars/sec)
        target_dur = max(833, (char_count / 20.0) * 1000)
        target_end = start + target_dur
        
        if target_end > end:
            max_end = start + 7000
            if i < len(subs) - 1:
                max_end = min(max_end, subs[i+1]['start'] - 83)
            
            if target_end < max_end: 
                end = target_end
            elif end < max_end: 
                end = max_end
                
        # 3. Strictly enforce gap (83ms) to the next subtitle
        if i < len(subs) - 1 and subs[i+1]['start'] - end < 83:
            end = subs[i+1]['start'] - 83
            
        if end <= start: 
            end = start + 100
            
        subs[i]['end'] = int(end)

    with open(outpath, 'w', encoding='utf-8') as f:
        for i, sub in enumerate(subs):
            f.write(f"{i+1}\n{format_time(sub['start'])} --> {format_time(sub['end'])}\n{sub['text']}\n\n")

process_srt(temp_srt, output_srt)
os.remove(temp_srt)

print(f"\nSuccess! Saved perfectly synced and cleaned file to: {output_srt}\n")
