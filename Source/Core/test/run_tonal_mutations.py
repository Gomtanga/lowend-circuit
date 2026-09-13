#!/usr/bin/env python3
"""Reproduce four tonal defects only in isolated copies; retain exact evidence."""
import argparse
import concurrent.futures
import difflib
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--repository', type=Path, default=Path(__file__).resolve().parents[3])
parser.add_argument('--evidence', type=Path, required=True)
args = parser.parse_args()
repository = args.repository.resolve()
evidence = args.evidence.resolve()
evidence.mkdir(parents=True, exist_ok=True)
scratch = Path(tempfile.mkdtemp(prefix='lowend-current-tonal-mutations-'))
snapshot = scratch / 'baseline-source'
for relative in ['Source/Core', 'SystemAudioProcessor/Sources/AudioRingBufferC',
                 'SystemAudioProcessor/Tests/AudioRingBufferChecks']:
    shutil.copytree(repository / relative, snapshot / relative)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

files = {str(path.relative_to(snapshot)): digest(path)
         for path in sorted(snapshot.rglob('*')) if path.is_file()}
with tarfile.open(evidence / 'linked-source-snapshot.tar.gz', 'w:gz') as archive:
    archive.add(snapshot, arcname='source')

def run(command, log):
    result = subprocess.run([str(item) for item in command], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    (evidence / log).write_text(result.stdout)
    return {'command': [str(item) for item in command], 'exit_code': result.returncode,
            'log': log, 'log_sha256': digest(evidence / log)}

baseline_build = scratch / 'baseline-build'
baseline = [run(['cmake', '-S', snapshot / 'Source/Core', '-B', baseline_build,
                 '-DCMAKE_BUILD_TYPE=Release', '-DLOWEND_CORE_BUILD_TESTING=ON'], 'baseline-configure.txt')]
if baseline[-1]['exit_code'] == 0:
    baseline.append(run(['cmake', '--build', baseline_build, '--parallel'], 'baseline-build.txt'))
if baseline[-1]['exit_code'] == 0:
    baseline.append(run(['ctest', '--test-dir', baseline_build, '--output-on-failure'], 'baseline-checks.txt'))
if len(baseline) != 3 or any(step['exit_code'] != 0 for step in baseline):
    (evidence / 'provenance.json').write_text(json.dumps({'baseline': baseline}, indent=2) + '\n')
    raise SystemExit('Fixed baseline must pass before mutation execution.')

def mutate(name):
    source = scratch / (name + '-source')
    shutil.copytree(snapshot, source)
    file = 'Source/Core/src/HighExciter.cpp'
    target = 'test_high_exciter'
    if name == 'circuit_discontinuous':
        file, target = 'Source/Core/src/CircuitBass.cpp', 'test_circuit_bass'
    elif name == 'float_coefficients':
        file, target = 'Source/Core/src/Core.cpp', 'test_precise_biquad'
    path = source / file
    before = path.read_text()
    if name == 'circuit_discontinuous':
        assert before.count('clipped = 2.0f / 3.0f;') == 1
        assert before.count('clipped = -2.0f / 3.0f;') == 1
        after = before.replace('clipped = 2.0f / 3.0f;', 'clipped = 1.0f;').replace(
            'clipped = -2.0f / 3.0f;', 'clipped = -1.0f;')
    elif name == 'exciter_dry_only':
        line = 'return isDry ? dry : fastClamp(dry + wet);'
        assert before.count(line) == 1
        after = before.replace(line, 'return dry;')
    elif name == 'exciter_dc_leak':
        after, count = re.subn(r'const float dcBlocked = \(1\.0f \+ dcBlockPole\) \* 0\.5f\s*'
                              r'\* \(harmonic - previousHarmonic\) \+ dcBlockPole \* previousDCBlocked;',
                              'const float dcBlocked = harmonic;', before)
        assert count == 1
    else:
        start = before.index('LCBiquadCoefficients64 Biquad64::makeLowShelf(')
        body = before.index('{', start)
        end = before.index('\n}', body)
        replacement = '''{
    const auto rounded = Biquad::makeLowShelf(static_cast<float>(sampleRate),
        static_cast<float>(frequency), static_cast<float>(q), static_cast<float>(gainDb));
    return { rounded.b0, rounded.b1, rounded.b2, rounded.a1, rounded.a2 };'''
        after = before[:body] + replacement + before[end:]
    assert after != before
    path.write_text(after)
    patch = ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                       fromfile='a/' + file, tofile='b/' + file))
    (evidence / (name + '.patch')).write_text(patch)
    build = scratch / (name + '-build')
    steps = [run(['cmake', '-S', source / 'Source/Core', '-B', build,
                  '-DCMAKE_BUILD_TYPE=Release', '-DLOWEND_CORE_BUILD_TESTING=ON'], name + '-configure.txt')]
    if steps[-1]['exit_code'] == 0:
        steps.append(run(['cmake', '--build', build, '--target', target, '--parallel'], name + '-build.txt'))
    if steps[-1]['exit_code'] == 0:
        steps.append(run([build / 'test' / target], name + '-checks.txt'))
    tested = len(steps) == 3 and all(step['exit_code'] == 0 for step in steps[:2])
    detected = tested and steps[2]['exit_code'] == 1 and 'FAIL:' in (evidence / steps[2]['log']).read_text()
    return {'name': name, 'mutated_file': file, 'before_sha256': files[file],
            'after_sha256': digest(path), 'patch': name + '.patch', 'steps': steps,
            'detected': detected, 'executable_sha256': digest(build / 'test' / target) if tested else None}

names = ['circuit_discontinuous', 'exciter_dry_only', 'exciter_dc_leak', 'float_coefficients']
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    mutants = list(pool.map(mutate, names))
unchanged = {relative: digest(repository / relative) == value for relative, value in files.items()}
result = {'scratch': str(scratch), 'source_files': files, 'source_snapshot': 'linked-source-snapshot.tar.gz',
          'snapshot_sha256': digest(evidence / 'linked-source-snapshot.tar.gz'),
          'toolchain': subprocess.check_output(['c++', '--version'], text=True),
          'baseline': baseline, 'mutants': mutants, 'repository_files_unchanged': all(unchanged.values()),
          'changed_repository_files': [name for name, same in unchanged.items() if not same]}
(evidence / 'provenance.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'baseline_exit_codes': [step['exit_code'] for step in baseline],
                  'detected': {m['name']: m['detected'] for m in mutants},
                  'repository_files_unchanged': result['repository_files_unchanged']}, indent=2))
raise SystemExit(0 if all(m['detected'] for m in mutants) and result['repository_files_unchanged'] else 1)
