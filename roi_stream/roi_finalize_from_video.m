function filename = roi_finalize_from_video(vid, summary, pulse_times)
%ROI_FINALIZE_FROM_VIDEO Flush ROI trace buffers and finalize the HDF5 file.

filename = '';
if nargin < 2 || isempty(summary)
    summary = struct();
end
if nargin < 3
    pulse_times = [];
end
if nargin < 1 || isempty(vid) || ~isvalid(vid)
    return;
end

try
    S = vid.UserData;
catch
    return;
end

if ~isstruct(S) || ~isfield(S, 'h5w') || isempty(S.h5w)
    return;
end

filename = char(S.h5w.path);

elapsed = [];
avgFPS = [];
if isfield(S, 'tic0') && isfield(S, 'framesSeen')
    elapsed = toc(S.tic0);
    avgFPS = S.framesSeen / max(elapsed, eps);
end

try
    [S, drainedInFinalize] = drain_remaining_frames_once(vid, S);
    if drainedInFinalize > 0 && ~isfield(summary, 'frames_drained_finalize')
        summary.frames_drained_finalize = uint64(drainedInFinalize);
    end

    if isfield(S, 'pending_n') && S.pending_n > 0
        S.h5w.append(S.pending_t(1:S.pending_n), S.pending_means(1:S.pending_n, :), []);
        S.pending_n = 0;
    end

    if ~isfield(summary, 'end_iso8601') || isempty(summary.end_iso8601)
        summary.end_iso8601 = char(datetime('now', 'TimeZone', 'local', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSZ'));
    end
    if ~isfield(summary, 'frames_seen') && isfield(S, 'framesSeen')
        summary.frames_seen = uint64(S.framesSeen);
    end
    if ~isfield(summary, 'frames_dropped') && isfield(S, 'framesDropped')
        summary.frames_dropped = uint64(S.framesDropped);
    end
    if ~isfield(summary, 'elapsed_sec') && ~isempty(elapsed)
        summary.elapsed_sec = double(elapsed);
    end
    if ~isfield(summary, 'avg_fps') && ~isempty(avgFPS)
        summary.avg_fps = double(avgFPS);
    end

    S.h5w.finalize(summary);
    if ~isempty(pulse_times)
        write_pulse_times(filename, pulse_times);
    end
catch ME
    warning('HDF5 finalize failed: %s', ME.message);
end

vid.UserData = S;
end

function write_pulse_times(h5path, pulse_times)
pulse_times = double(pulse_times(:));
if isempty(pulse_times)
    return;
end

try
    h5info(h5path, '/events/pulse_times');
catch
    h5create(h5path, '/events/pulse_times', size(pulse_times), 'Datatype', 'double');
end
h5write(h5path, '/events/pulse_times', pulse_times);
end

function [S, drainedCount] = drain_remaining_frames_once(vid, S)
% Drain any buffered frames that are still in videoinput memory at stop time.
% This is a post-stop, one-time catch-up pass to reduce tail-frame loss in H5.

drainedCount = 0;
if nargin < 2 || ~isstruct(S) || nargin < 1 || isempty(vid) || ~isvalid(vid)
    return;
end

startSeen = 0;
if isfield(S, 'framesSeen') && ~isempty(S.framesSeen)
    startSeen = double(S.framesSeen);
end

origStrict = [];
if isfield(S, 'strictNoDrop')
    origStrict = S.strictNoDrop;
else
    S.strictNoDrop = true;
end
S.strictNoDrop = true;
vid.UserData = S;

maxIters = 1000;
for i = 1:maxIters
    avail = 0;
    try
        avail = double(vid.FramesAvailable);
    catch
        break;
    end
    if avail <= 0
        break;
    end

    try
        roi_on_frame(vid, []);
    catch ME
        if contains(ME.message, 'no data is currently available', 'IgnoreCase', true) || ...
           contains(ME.identifier, 'imaqdevice', 'IgnoreCase', true)
            break;
        end
        warning('roi_stream:FinalizeDrainFailed', 'Finalize drain stopped: %s', ME.message);
        break;
    end

    try
        S = vid.UserData;
    catch
        break;
    end
end

if ~isempty(origStrict)
    S.strictNoDrop = origStrict;
end
vid.UserData = S;

if isfield(S, 'framesSeen') && ~isempty(S.framesSeen)
    drainedCount = max(0, double(S.framesSeen) - startSeen);
end
end
