function report = diagnose_frame_discrepancy(runDir, stem)
%DIAGNOSE_FRAME_DISCREPANCY Pinpoint AVI/H5/BCAM frame-count mismatches.
%
% report = diagnose_frame_discrepancy(runDir, stem)
%   runDir : directory with <stem>.avi, <stem>_roi.h5, <stem>_bcam.mat
%   stem   : base recording name

if nargin < 1 || isempty(runDir)
    runDir = fullfile(fileparts(mfilename('fullpath')), 'test_run');
end
if nargin < 2 || isempty(stem)
    d = dir(fullfile(runDir, '*.avi'));
    if numel(d) ~= 1
        error('Pass stem explicitly when runDir has 0 or >1 avi files.');
    end
    stem = erase(d(1).name, '.avi');
end
stem = char(string(stem));

aviPath = fullfile(runDir, [stem '.avi']);
h5Path = fullfile(runDir, [stem '_roi.h5']);
bcamPath = fullfile(runDir, [stem '_bcam.mat']);

% --- Load counts
vr = VideoReader(aviPath);
nAvi = 0;
while hasFrame(vr)
    readFrame(vr); %#ok<NASGU>
    nAvi = nAvi + 1;
end
nH5 = h5info(h5Path, '/time').Dataspace.Size(1);
S = load(bcamPath);
bcl = S.bcl;
t = double(bcl{3}(:));
cam = double(bcl{8}(:));

% --- TTL rises
thr = min(cam) + 0.5 * (max(cam) - min(cam));
hi = cam > thr;
r = find(~hi(1:end-1) & hi(2:end)) + 1;
tr = t(r);
nRise = numel(r);

% --- Align video start to DAQ time axis via stored datetimes
tVidStart = datetime(bcl{1});
tScanStart = datetime(bcl{2});
videoStartSec = seconds(tVidStart - tScanStart);
[~, iStart] = min(abs(tr - videoStartSec));

iAviEnd = iStart + nAvi - 1;
iH5End = iStart + nH5 - 1;

tailAfterAvi = max(0, nRise - iAviEnd);
tailAfterH5 = max(0, nRise - iH5End);
headBeforeStart = iStart - 1;

fprintf('\n[discrepancy] stem=%s\n', stem);
fprintf('  counts: AVI=%d, H5=%d, BCAM rises=%d\n', nAvi, nH5, nRise);
fprintf('  deltas: AVI-H5=%d, BCAM-AVI=%d, BCAM-H5=%d\n', nAvi-nH5, nRise-nAvi, nRise-nH5);
fprintf('  video_start_sec_from_scan = %.6f\n', videoStartSec);
fprintf('  nearest TTL rise index     = %d @ %.6f s\n', iStart, tr(iStart));
fprintf('  TTL rises before start     = %d\n', headBeforeStart);
fprintf('  TTL rises after AVI end    = %d\n', tailAfterAvi);
fprintf('  TTL rises after H5 end     = %d\n', tailAfterH5);

if (nAvi - nH5) == 1 && tailAfterAvi >= 2 && iStart >= 3
    fprintf(['  interpretation: most mismatch is boundary timing:\n' ...
             '    - DAQ captured extra camera pulses before/after video window.\n' ...
             '    - H5 is short by ~1 frame versus AVI (likely stop-time callback race).\n']);
end
fprintf('\n');

report = struct();
report.paths = struct('avi', aviPath, 'h5', h5Path, 'bcam', bcamPath);
report.counts = struct('avi', nAvi, 'h5', nH5, 'bcam_rises', nRise);
report.alignment = struct( ...
    'video_start_sec_from_scan', videoStartSec, ...
    'start_rise_index', iStart, ...
    'head_before_start', headBeforeStart, ...
    'tail_after_avi_end', tailAfterAvi, ...
    'tail_after_h5_end', tailAfterH5);
end
