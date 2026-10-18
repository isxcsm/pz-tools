"""A picture of each sound, to judge it without hearing it (SOUND-SYSTEM.md S5): its waveform, its spectrogram (0 to 16 kHz,
log magnitude), and its numbers: length, peak, RMS, the loudest 50 ms (dBFS), the frequency its energy centres on, and when
its loudest moment comes (the attack). One PNG a file, and a summary table, in report/ (not kept in git).

    python -X utf8 report.py                     every built sound of the mods (media/sound/*.ogg)
    python -X utf8 report.py file_or_folder ...  those files (a folder: its sound files)

The pictures are for the eye: a click is a thin bright stripe, a hiss a band to the top, a thud the bottom of the
spectrogram; a tail that runs on shows as a long fade. The ear is the user's.
"""
import glob
import os
import subprocess
import sys
import tempfile

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
MODS = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, 'report')
RATE = 44100
EXTS = ('.ogg', '.wav', '.flac', '.mp3')


def decode(path):
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, 'in.wav')
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', path, '-ac', '1', '-ar', str(RATE),
                        '-c:a', 'pcm_f32le', wav], check=True, stdin=subprocess.DEVNULL)
        data, _ = sf.read(wav, dtype='float32')
    return data


def db(x):
    return 20 * np.log10(max(float(x), 1e-9))


def numbers(data):
    win = int(0.05 * RATE)
    if len(data) >= win:
        power = np.convolve(data.astype(np.float64) ** 2, np.ones(win) / win, mode='valid')
        loudest = db(np.sqrt(power.max()))
        attack = (int(np.argmax(power)) + win / 2) / RATE
    else:
        loudest = db(np.sqrt(np.mean(data ** 2)))
        attack = 0.0
    spectrum = np.abs(np.fft.rfft(data * np.hanning(len(data)))) if len(data) > 1 else np.zeros(1)
    freqs = np.fft.rfftfreq(len(data), 1 / RATE) if len(data) > 1 else np.zeros(1)
    centre = float((freqs * spectrum).sum() / max(spectrum.sum(), 1e-9))
    return {
        'length_s': len(data) / RATE,
        'peak_db': db(np.max(np.abs(data)) if len(data) else 0),
        'rms_db': db(np.sqrt(np.mean(data ** 2)) if len(data) else 0),
        'loudest50_db': loudest,
        'centre_hz': centre,
        'attack_s': attack,
    }


def picture(path, data, n, out):
    fig, (wave, spec) = plt.subplots(2, 1, figsize=(9, 5), sharex=True, gridspec_kw={'height_ratios': [1, 2]})
    t = np.arange(len(data)) / RATE
    wave.plot(t, data, linewidth=0.5, color='#335')
    wave.set_ylim(-1, 1)
    wave.set_ylabel('amplitude')
    wave.set_title('%s  |  %.3f s  peak %.1f  rms %.1f  loudest50 %.1f dBFS  centre %.0f Hz  attack %.3f s' % (
        os.path.basename(path), n['length_s'], n['peak_db'], n['rms_db'], n['loudest50_db'], n['centre_hz'], n['attack_s']),
        fontsize=8)
    if len(data) > 256:
        spec.specgram(data, NFFT=512, Fs=RATE, noverlap=448, cmap='magma', vmin=-120)
    spec.set_ylim(0, 16000)
    spec.set_ylabel('Hz')
    spec.set_xlabel('s')
    fig.tight_layout()
    fig.savefig(out, dpi=90)
    plt.close(fig)


def files(args):
    if not args:
        return sorted(glob.glob(os.path.join(MODS, '*', '*', '42', 'media', 'sound', '*.ogg')))
    found = []
    for a in args:
        if os.path.isdir(a):
            found += sorted(p for p in glob.glob(os.path.join(a, '**', '*'), recursive=True) if p.lower().endswith(EXTS))
        else:
            found.append(a)
    return found


def main(args):
    os.makedirs(OUT, exist_ok=True)
    rows = []
    for path in files(args):
        data = decode(path)
        n = numbers(data)
        name = os.path.splitext(os.path.basename(path))[0]
        picture(path, data, n, os.path.join(OUT, name + '.png'))
        rows.append((name, n))
    with open(os.path.join(OUT, 'summary.txt'), 'w', encoding='utf-8') as f:
        f.write('%-32s %8s %8s %8s %10s %9s %8s\n' % ('sound', 'len s', 'peak', 'rms', 'loud50', 'centre', 'attack'))
        for name, n in rows:
            f.write('%-32s %8.3f %8.1f %8.1f %10.1f %9.0f %8.3f\n' % (name, n['length_s'], n['peak_db'], n['rms_db'],
                                                                   n['loudest50_db'], n['centre_hz'], n['attack_s']))
    print('%d sounds -> %s' % (len(rows), os.path.relpath(OUT, MODS)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
