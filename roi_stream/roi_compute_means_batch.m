function meansBatch = roi_compute_means_batch(f16batch, roi)
%ROI_COMPUTE_MEANS_BATCH Per-ROI means for a batch of uint16 frames.
%   f16batch : HxWxN uint16 image batch
%   roi      : struct with fields .idx (cell) and .npix (uint32)
% Returns:
%   meansBatch : NxK single, where K is number of ROIs

if ndims(f16batch) ~= 3
    error('roi_stream:InvalidBatch', 'f16batch must be HxWxN.');
end

[H, W, N] = size(f16batch);
K = numel(roi.npix);
meansBatch = nan(N, K, 'single');

X = reshape(f16batch, H * W, N);
for k = 1:K
    npix = double(roi.npix(k));
    if npix <= 0
        continue;
    end
    idx = roi.idx{k};
    if isempty(idx)
        continue;
    end
    % Sum all selected pixels for every frame at once.
    s = sum(double(X(idx, :)), 1);
    meansBatch(:, k) = single(s(:) / npix);
end
end
