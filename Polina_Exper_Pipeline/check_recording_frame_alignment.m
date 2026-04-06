function result = check_recording_frame_alignment(runDir, stem)
%CHECK_RECORDING_FRAME_ALIGNMENT Compare frame counts across AVI/H5/BCAM TTL.
%
% result = check_recording_frame_alignment(runDir, stem)
%   runDir : folder containing <stem>.avi, <stem>_roi.h5, <stem>_bcam.mat
%            default: <this file folder>/test_run
%   stem   : recording stem (e.g., "tt"). If omitted, auto-select when unique.
%
% The function prints a short report and returns a struct with all counts.

if nargin < 1 || isempty(runDir)
    runDir = fullfile(fileparts(mfilename('fullpath')), 'test_run');
end

if nargin < 2 || isempty(stem)
    aviList = dir(fullfile(runDir, '*.avi'));
    if isempty(aviList)
        error('No AVI files found in: %s', runDir);
    end
    if numel(aviList) ~= 1
        names = string({aviList.name});
        error('Multiple AVI files found. Pass stem explicitly. Found: %s', strjoin(names, ', '));
    end
    stem = erase(aviList(1).name, '.avi');
end
stem = char(string(stem));

aviPath = fullfile(runDir, [stem '.avi']);
h5Path = fullfile(runDir, [stem '_roi.h5']);
bcamPath = fullfile(runDir, [stem '_bcam.mat']);

mustExist(aviPath);
mustExist(h5Path);
mustExist(bcamPath);

% --- AVI frame count (decode-based for reliability)
vr = VideoReader(aviPath);
nAvi = 0;
while hasFrame(vr)
    readFrame(vr); %#ok<NASGU>
    nAvi = nAvi + 1;
end

% --- ROI HDF5 frame count
h5infoTime = h5info(h5Path, '/time');
nH5Time = h5infoTime.Dataspace.Size(1);
h5infoMeans = h5info(h5Path, '/roi/means');
nH5Means = h5infoMeans.Dataspace.Size(1);

% --- BCAM TTL frame count from camera channel
S = load(bcamPath);
if isfield(S, 'bcl')
    bcl = S.bcl;
else
    fns = fieldnames(S);
    error('Expected variable ''bcl'' in %s. Found: %s', bcamPath, strjoin(fns, ', '));
end

cam = extract_camera_channel(bcl);
[ttlRises, ttlFramesInclFirstHigh, threshold, riseIdx] = count_ttl_rising_edges(cam);

% Post-processing gate: count only TTL rises during the video window.
% We intentionally do not change recording behavior; this is analysis only.
ttlRisesInVideoWindow = NaN;
ttlFramesInVideoWindow = NaN;
videoWindow = [NaN NaN];
if iscell(bcl) && numel(bcl) >= 3 && isnumeric(bcl{3}) && numel(bcl) >= 2
    try
        tDaq = double(bcl{3}(:)); % DAQ sample times (sec from scan start)
        tVidStart = datetime(bcl{1});
        tScanStart = datetime(bcl{2});
        vidStartSec = seconds(tVidStart - tScanStart);
        framePeriod = estimate_frame_period_for_gate(h5Path, tDaq, riseIdx);
        vidStopSec = vidStartSec + (nAvi - 1) * framePeriod;
        videoWindow = [vidStartSec vidStopSec];

        riseTimes = tDaq(riseIdx);
        inWin = (riseTimes >= vidStartSec) & (riseTimes <= vidStopSec);
        ttlRisesInVideoWindow = sum(inWin);
        % Include a possible initial-high pulse at the first DAQ sample within window.
        i0 = find(tDaq >= vidStartSec, 1, 'first');
        initHigh = 0;
        if ~isempty(i0)
            hi = cam > threshold;
            initHigh = double(hi(i0));
        end
        ttlFramesInVideoWindow = ttlRisesInVideoWindow + initHigh;
    catch
    end
end

% --- Compare
diffAviVsH5 = nAvi - nH5Time;
diffAviVsTTL = nAvi - ttlFramesInclFirstHigh;
diffH5VsTTL = nH5Time - ttlFramesInclFirstHigh;
diffAviVsTTLGated = nAvi - ttlFramesInVideoWindow;
diffH5VsTTLGated = nH5Time - ttlFramesInVideoWindow;

result = struct();
result.runDir = runDir;
result.stem = stem;
result.aviPath = aviPath;
result.h5Path = h5Path;
result.bcamPath = bcamPath;
result.counts = struct( ...
    'avi_frames', nAvi, ...
    'h5_time_rows', nH5Time, ...
    'h5_means_rows', nH5Means, ...
    'bcam_ttl_rises', ttlRises, ...
    'bcam_frames_including_initial_high', ttlFramesInclFirstHigh, ...
    'bcam_ttl_rises_video_window', ttlRisesInVideoWindow, ...
    'bcam_frames_video_window', ttlFramesInVideoWindow);
result.threshold = threshold;
result.video_window_sec = videoWindow;
result.deltas = struct( ...
    'avi_minus_h5', diffAviVsH5, ...
    'avi_minus_bcam', diffAviVsTTL, ...
    'h5_minus_bcam', diffH5VsTTL, ...
    'avi_minus_bcam_gated', diffAviVsTTLGated, ...
    'h5_minus_bcam_gated', diffH5VsTTLGated);
result.all_match_exact = (nAvi == nH5Time) && (nH5Time == nH5Means) && (nH5Time == ttlFramesInVideoWindow);

fprintf('\n[frame-check] stem=%s\n', stem);
fprintf('  AVI frames                : %d\n', nAvi);
fprintf('  H5 /time rows             : %d\n', nH5Time);
fprintf('  H5 /roi/means rows        : %d\n', nH5Means);
fprintf('  BCAM TTL rises            : %d\n', ttlRises);
fprintf('  BCAM frames (incl 1st hi) : %d\n', ttlFramesInclFirstHigh);
if ~isnan(ttlFramesInVideoWindow)
    fprintf('  BCAM rises in video win   : %d\n', ttlRisesInVideoWindow);
    fprintf('  BCAM frames in video win  : %d\n', ttlFramesInVideoWindow);
    fprintf('  Video window (scan sec)   : [%.6f, %.6f]\n', videoWindow(1), videoWindow(2));
end
fprintf('  TTL threshold             : %.6g\n', threshold);
fprintf('  deltas [avi-h5, avi-bcam(raw), h5-bcam(raw)] = [%d, %d, %d]\n', ...
    diffAviVsH5, diffAviVsTTL, diffH5VsTTL);
if ~isnan(ttlFramesInVideoWindow)
    fprintf('  deltas [avi-bcam(gated), h5-bcam(gated)] = [%d, %d]\n', ...
        diffAviVsTTLGated, diffH5VsTTLGated);
end

if result.all_match_exact
    fprintf('[frame-check] PASS: counts match exactly.\n');
else
    fprintf('[frame-check] WARN: counts do not all match exactly.\n');
end
fprintf('\n');
end

function mustExist(p)
if ~isfile(p)
    error('File not found: %s', p);
end
end

function cam = extract_camera_channel(bcl)
if iscell(bcl)
    if numel(bcl) >= 8 && isnumeric(bcl{8})
        cam = bcl{8};
        return;
    end
    % Fallback: pick last numeric vector in the cell array.
    for i = numel(bcl):-1:1
        if isnumeric(bcl{i}) && isvector(bcl{i})
            cam = bcl{i};
            return;
        end
    end
end
error('Could not locate camera TTL channel in bcl.');
end

function [nRises, nFramesInclFirstHigh, thr, riseIdx] = count_ttl_rising_edges(x)
x = double(x(:));
if isempty(x)
    nRises = 0;
    nFramesInclFirstHigh = 0;
    thr = NaN;
    riseIdx = zeros(0,1);
    return;
end

xMin = min(x);
xMax = max(x);
thr = xMin + 0.5 * (xMax - xMin);
hi = x > thr;
riseIdx = find(~hi(1:end-1) & hi(2:end)) + 1;
nRises = numel(riseIdx);
nFramesInclFirstHigh = nRises + double(hi(1));
end

function framePeriod = estimate_frame_period_for_gate(h5Path, tDaq, riseIdx)
% Prefer DAQ camera TTL rise spacing for gating on DAQ timeline.
framePeriod = NaN;
if ~isempty(riseIdx) && numel(riseIdx) >= 3
    tr = tDaq(riseIdx);
    dt = diff(tr);
    framePeriod = median(dt(isfinite(dt) & dt > 0));
end

% Fallback: H5 /time spacing.
if ~isfinite(framePeriod) || framePeriod <= 0
try
    tH5 = h5read(h5Path, '/time');
    tH5 = double(tH5(:));
    if numel(tH5) >= 3
        dt = diff(tH5);
        framePeriod = median(dt(isfinite(dt) & dt > 0));
    end
catch
end
end

% Final fallback for this rig.
if ~isfinite(framePeriod) || framePeriod <= 0
    framePeriod = 1 / 80;
end
end
