function roiDir = ensure_roi_stream_path(baseDir)
%ENSURE_ROI_STREAM_PATH Add the shared roi_stream library folder to MATLAB path.

if nargin < 1 || isempty(baseDir)
    baseDir = fileparts(mfilename('fullpath'));
end

roiDir = fullfile(baseDir, 'roi_stream');
if exist(roiDir, 'dir') ~= 7
    error('roi_stream library folder not found: %s', roiDir);
end

if ~contains(path, roiDir)
    addpath(roiDir);
end
end
