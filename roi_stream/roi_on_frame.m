function roi_on_frame(obj, ~)
%ROI_ON_FRAME Per-frame callback used by roi_stream and embedded pipelines.

S = obj.UserData;

if ~isfield(S, 'callbackBatchFrames') || isempty(S.callbackBatchFrames)
    S.callbackBatchFrames = 1;
end
if ~isfield(S, 'strictNoDrop') || isempty(S.strictNoDrop)
    S.strictNoDrop = false;
end

avail = obj.FramesAvailable;
if avail <= 0
    return;
end

nToRead = min(avail, S.callbackBatchFrames);

try
    framesRaw = getdata(obj, nToRead, 'native');
catch ME
    % Can occur transiently when stopping/reconfiguring a stream or if
    % no frame is currently available to read.
    if contains(ME.message, 'no data is currently available', 'IgnoreCase', true) || ...
       contains(ME.identifier, 'imaqdevice', 'IgnoreCase', true)
        return;
    end
    rethrow(ME);
end

% In non-strict mode, intentionally drop backlog to keep memory bounded.
if ~S.strictNoDrop
    backlog = obj.FramesAvailable;
    if backlog > 0
        S.framesDropped = S.framesDropped + backlog;
        try
            flushdata(obj, 'triggers');
        catch
            try
                flushdata(obj);
            catch
            end
        end
    end
end

[f16batch, nFrames] = to_uint16_gray_batch(framesRaw, nToRead);
if nFrames <= 0
    obj.UserData = S;
    return;
end

% Some devices/reporting paths (notably preview/cropped ROI streams) can
% produce frames whose size differs from attach-time VideoResolution.
% Rebuild indices from stored ROI circles when this happens, or when
% precomputed indices are out of bounds for the incoming frame.
[Hf, Wf, ~] = size(f16batch);
if ~isfield(S, 'roi') || ~isfield(S.roi, 'circles')
    error('roi_stream:MissingROIState', 'ROI state missing from video UserData.');
end

frameShapeMismatch = ~isfield(S.roi, 'frame_size') || ~isequal(S.roi.frame_size, [Hf Wf]);
frameIndexOverflow = false;
if isfield(S.roi, 'max_idx')
    frameIndexOverflow = double(S.roi.max_idx) > (Hf * Wf);
end

if frameShapeMismatch || frameIndexOverflow
    S.roi = roi_build_circle_indices(Hf, Wf, S.roi.circles);
    if ~isfield(S, 'warnedFrameSizeAdjust') || ~S.warnedFrameSizeAdjust
        fprintf('[roi_stream] Adjusted ROI indices for %dx%d frames.\n', Wf, Hf);
        S.warnedFrameSizeAdjust = true;
    end
end
meansBatch = roi_compute_means_batch(f16batch, S.roi);

tNow = toc(S.tic0);
if nFrames == 1 || S.lastFrameTime <= 0
    tBatch = tNow;
    if nFrames > 1
        dt = max(1/2000, eps);
        tBatch = tNow + dt*((1:nFrames)' - nFrames);
    end
else
    dt = max((tNow - S.lastFrameTime) / nFrames, 1/2000);
    tBatch = S.lastFrameTime + dt*(1:nFrames)';
end

S.framesSeen = S.framesSeen + nFrames;
S.frametimes(end+1:end+nFrames) = tBatch.';
if numel(S.frametimes) > S.maxFT
    S.frametimes = S.frametimes(end - S.maxFT + 1:end);
end

if (tNow - S.lastPrint) >= S.printEvery
    ft = S.frametimes;
    fps = NaN;
    if numel(ft) >= 2
        fps = (numel(ft) - 1) / max(ft(end) - ft(1), eps);
    end
    fprintf('[%7.3fs] FPS: %5.1f   frames=%d   dropped=%d\n', ...
        tNow, fps, S.framesSeen, S.framesDropped);
    S.lastPrint = tNow;
end

S.lastFrame = f16batch(:,:,end);
S.lastFrameTime = tBatch(end);

cap = S.trace_capacity;
for i = 1:nFrames
    head = S.trace_head + 1;
    if head > cap
        head = 1;
    end
    S.trace_head = head;
    S.trace_t(head) = tBatch(i);
    S.trace_means(head, :) = meansBatch(i, :);

    S.pending_n = S.pending_n + 1;
    S.pending_t(S.pending_n) = tBatch(i);
    S.pending_means(S.pending_n, :) = meansBatch(i, :);

    if S.loggingEnabled && S.pending_n >= S.framesPerChunk && ~isempty(S.h5w)
        S.h5w.append(S.pending_t(1:S.pending_n), S.pending_means(1:S.pending_n, :), []);
        S.pending_n = 0;
    end
end

obj.UserData = S;
end

function [f16batch, nFrames] = to_uint16_gray_batch(framesRaw, nExpected)
if nargin < 2 || isempty(nExpected)
    nExpected = 1;
end

if iscell(framesRaw)
    nFrames = numel(framesRaw);
    if nFrames == 0
        f16batch = zeros(0,0,0,'uint16');
        return;
    end
    f0 = to_uint16_gray(framesRaw{1});
    [H, W] = size(f0);
    f16batch = zeros(H, W, nFrames, 'uint16');
    f16batch(:,:,1) = f0;
    for i = 2:nFrames
        f16batch(:,:,i) = to_uint16_gray(framesRaw{i});
    end
    return;
end

if ndims(framesRaw) == 2
    f16batch = to_uint16_gray(framesRaw);
    f16batch = reshape(f16batch, size(f16batch,1), size(f16batch,2), 1);
    nFrames = 1;
    return;
end

sz = size(framesRaw);
if ndims(framesRaw) == 3
    if sz(3) == 3 && nExpected == 1
        f16batch = to_uint16_gray(framesRaw);
        f16batch = reshape(f16batch, size(f16batch,1), size(f16batch,2), 1);
        nFrames = 1;
        return;
    end
    nFrames = sz(3);
    f16batch = zeros(sz(1), sz(2), nFrames, 'uint16');
    for i = 1:nFrames
        f16batch(:,:,i) = to_uint16_gray(framesRaw(:,:,i));
    end
    return;
end

if ndims(framesRaw) == 4
    nFrames = sz(4);
    f16batch = zeros(sz(1), sz(2), nFrames, 'uint16');
    for i = 1:nFrames
        f16batch(:,:,i) = to_uint16_gray(framesRaw(:,:,:,i));
    end
    return;
end

error('roi_stream:UnsupportedFrameShape', 'Unsupported frame array shape from getdata.');
end
