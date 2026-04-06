classdef ExperimentalGUI_TCNoStim_exported < matlab.apps.AppBase

    % Properties that correspond to app components
    properties (Access = public)
        UIFigure                        matlab.ui.Figure
        StartExperimentButton           matlab.ui.control.StateButton
        NALabel_2                       matlab.ui.control.Label
        TimeStartedLabel                matlab.ui.control.Label
        StartingupLabel                 matlab.ui.control.Label
        StatusLabel                     matlab.ui.control.Label
        VideoFilenameEditField          matlab.ui.control.EditField
        VideoFilenameEditFieldLabel     matlab.ui.control.Label
        LoggingDirectoryEditField       matlab.ui.control.EditField
        LoggingDirectoryEditFieldLabel  matlab.ui.control.Label
        LoggingControlsLabel            matlab.ui.control.Label
        PreviewROIGUIButton             matlab.ui.control.Button
        TransCoordsFileEditField        matlab.ui.control.EditField
        TransCoordsFileEditFieldLabel   matlab.ui.control.Label
    end

    
    properties (Access = private)
        v
        src
        dqIn
        lsr
        numROIs
        FrameRate
        bcam_log
        bcamfullFilename
        roifullFilename
        scan_start
        previewVid
        previewFig
        experimentRunning = false
        stopRequested = false
        
    end
    

    % Callbacks that handle component events
    methods (Access = private)

        % Code that executes after component creation
        function startupFcn(app)
            warning('off','all')
            appDir = fileparts(mfilename('fullpath'));
            addpath(fullfile(fileparts(appDir), 'roi_stream'));

            % Change label to idle
            app.StartingupLabel.Text = 'Idle';
            app.previewVid = [];
            app.previewFig = [];
            app.configureDefaultCalibrationFiles(appDir);

        end

        % Value changed function: StartExperimentButton
        function StartExperimentButtonValueChanged(app, event)
            value = app.StartExperimentButton.Value;
            
            if value

                app.experimentRunning = true;
                app.stopRequested = false;

                app.StartExperimentButton.Enable = "off";
                app.LoggingDirectoryEditField.Enable = "off";
                app.VideoFilenameEditField.Enable = "off";

                logDir = char(string(app.LoggingDirectoryEditField.Value));
                if isempty(strtrim(logDir))
                    error('Logging directory is empty.');
                end
                if ~isfolder(logDir)
                    [ok, msg] = mkdir(logDir);
                    if ~ok
                        error('Could not create logging directory: %s', msg);
                    end
                end
                app.LoggingDirectoryEditField.Value = string(logDir);

                % Get everything ready according to set protocol values
                app.StartingupLabel.Text = 'Preparing for recording...';

                app.numROIs = 6;

                app.FrameRate = 80; % Hz
                
                % Clear recording variables if they already exist
                if ~isempty(app.v)
                    try
                        if isvalid(app.v)
                            delete(app.v);
                        end
                    catch
                    end
                    app.v = [];
                end
                if ~isempty(app.dqIn)
                    try
                        delete(app.dqIn);
                    catch
                    end
                    app.dqIn = [];
                end
                
                % Connect to camera
                app.v = videoinput("hamamatsu", 1, "MONO16_BIN2x2_1152x1152_Fast");
                app.v.ROIPosition = [0 160 576 238]*2;

                app.src = getselectedsource(app.v);
                app.src.OutputTriggerKindOpt1 = "exposure";
                app.src.OutputTriggerPolarityOpt1 = "positive";
                app.src.ExposureTime = 1/app.FrameRate;

                app.lsr = lsrCtrlParams;

                
                
                % Set up DAQ
                app.dqIn = daq("ni");
                
                addinput(app.dqIn, "Dev1", "ai0", "Voltage"); % Rig 1 TTL pulses for syncing 
                addinput(app.dqIn, "Dev1", "ai2", "Voltage"); % Rig 2 TTL pulses for syncing
                addinput(app.dqIn, "Dev1", "ai4", "Voltage"); % 488 LED firing voltage pulse
                addinput(app.dqIn, "Dev1", "ai6", "Voltage"); % 420 LED firing voltage pulse
                addinput(app.dqIn, "Dev1", "ai7", "Voltage"); % camera voltage pulse -- should be frame perfect match of .avi frames

                app.dqIn.Rate = 2000;

                app.lsr = lsrCtrlParams; % get class object with laser parameters


                % Set up video recording
                fullFilename = fullfile(logDir, app.VideoFilenameEditField.Value+".avi");
                logfile = VideoWriter(fullFilename, "Grayscale AVI");
                app.v.LoggingMode = "disk&memory";
                app.v.DiskLogger = logfile;
                app.v.FramesPerTrigger = Inf;

                % Set up bcam log
                app.bcamfullFilename = fullfile(logDir, app.VideoFilenameEditField.Value+"_bcam.mat");
                app.roifullFilename = fullfile(logDir, app.VideoFilenameEditField.Value+"_roi.h5");

                appDir = fileparts(mfilename('fullpath'));
                [coordsPath, coordsDisplay] = app.resolveFileInput(appDir, app.TransCoordsFileEditField.Value);
                if isempty(coordsPath)
                    error('Translated coordinates file is missing or invalid.');
                end
                app.TransCoordsFileEditField.Value = coordsDisplay;
                data = load(coordsPath, 'translated_coords');
                if ~isfield(data, 'translated_coords') || size(data.translated_coords, 2) < 3
                    error('Translated coordinates file must contain translated_coords(:,1:3).');
                end
                roiCircles = data.translated_coords(:, 1:3);
                roiMeta = struct( ...
                    'video_log_path', string(fullFilename), ...
                    'trans_coords_file', string(app.TransCoordsFileEditField.Value), ...
                    'requested_frame_rate_hz', double(app.FrameRate));
                roi_attach_to_video(app.v, roiCircles, struct( ...
                    'H5Path', app.roifullFilename, ...
                    'Meta', roiMeta, ...
                    'CallbackBatchFrames', 8, ...
                    'StrictNoDrop', true, ...
                    'PrintFPSPeriod', 2.0));

                % Read in bcam log inputs continuously
                start(app.dqIn, "Continuous")
                app.StartingupLabel.Text = 'Recording...';

                % Start recording
                start(app.v);
                app.lsr.time_start_vid = datetime("now", 'Format', 'HH:mm:ss.SSSSSSSSS');
                
                app.NALabel_2.Enable = true;
                app.NALabel_2.Text = sprintf("%s", app.lsr.time_start_vid);
                

                app.StartExperimentButton.Text = 'Stop Experiment';
                app.StartExperimentButton.Enable = "on";


            else
                app.stopRequested = true;
                
                % Stop recording
                app.StartingupLabel.Text = 'Saving video...';
                app.StartExperimentButton.Enable = "off";

                stop(app.v);

                % Stop NI DAQ acquisition
                stop(app.dqIn);
                [input_logs, timestamps, trigtime] = read(app.dqIn, 'all', "OutputFormat", "Matrix");

                scan_start = datetime(trigtime,'ConvertFrom','datenum','Format','HH:mm:ss.SSSSSSSSS');
                app.scan_start = scan_start;
                
                
                % Same frame time stamp log
                app.StartingupLabel.Text = 'Saving behavior cam log...';
                drawnow
                
                % addinput(app.dqIn, "Dev1", "ai0", "Voltage"); % Rig 1 TTL pulses for syncing 
                % addinput(app.dqIn, "Dev1", "ai2", "Voltage"); % Rig 2 TTL pulses for syncing
                % addinput(app.dqIn, "Dev1", "ai4", "Voltage"); % 488 LED firing voltage pulse
                % addinput(app.dqIn, "Dev1", "ai6", "Voltage"); % 420 LED firing voltage pulse
                % addinput(app.dqIn, "Dev1", "ai7", "Voltage"); % camera voltage pulse -- should be frame perfect match of .avi frames

                app.bcam_log{3} = timestamps; % DAQinput time stamps
                app.bcam_log{4} = input_logs(:, 1); % Rig 1 TTL pulses for syncing 
                app.bcam_log{5} = input_logs(:, 2); % Rig 2 TTL pulses for syncing
                app.bcam_log{6} = input_logs(:, 3); % 488 LED firing voltage pulse
                app.bcam_log{7} = input_logs(:, 4); % 420 LED firing voltage pulse
                app.bcam_log{8} = input_logs(:, 5); % camera voltage pulse

                app.bcam_log{1} = app.lsr.time_start_vid; % computer time of video start
                app.bcam_log{2} = scan_start; % DAQ time of scan start
                bcl = app.bcam_log;
                save(app.bcamfullFilename, "bcl");

                app.safeFinalizeROITrace([], struct('run_failed', false));
                app.safeStopAndDeleteObjects();

                % Change label to idle
                app.StartingupLabel.Text = 'Idle';
                app.NALabel_2.Enable = "off";
                app.NALabel_2.Text = "N/A";

                % Change Button Label
                app.StartExperimentButton.Text = 'Start Experiment';
                app.StartExperimentButton.Enable = "on";
                app.LoggingDirectoryEditField.Enable = "on";
                app.VideoFilenameEditField.Enable = "on";
                app.experimentRunning = false;
                app.stopRequested = false;

            end

            
        end

        % Value changed function: LoggingDirectoryEditField
        function LoggingDirectoryEditFieldValueChanged(app, event)
            logDir = char(string(app.LoggingDirectoryEditField.Value));
            if isempty(strtrim(logDir))
                return;
            end
            if ~isfolder(logDir)
                [ok, msg] = mkdir(logDir);
                if ~ok
                    errordlg(sprintf('Could not create logging directory:\n%s', msg), 'Directory Error');
                    return;
                end
            end
            app.LoggingDirectoryEditField.Value = string(logDir);
            
        end

        function safeFinalizeROITrace(app, pulse_times, extraSummary)
            if nargin < 2
                pulse_times = [];
            end
            if nargin < 3 || isempty(extraSummary)
                extraSummary = struct();
            end

            if isempty(app.v)
                return;
            end
            try
                if isvalid(app.v)
                    roiSummary = extraSummary;
                    if ~isempty(app.lsr) && isprop(app.lsr, 'time_start_vid') && ~isempty(app.lsr.time_start_vid)
                        roiSummary.video_start_time = char(app.lsr.time_start_vid);
                    end
                    if ~isempty(app.scan_start)
                        roiSummary.scan_start_time = char(app.scan_start);
                    end
                    if ~isempty(app.bcamfullFilename)
                        roiSummary.bcam_log_path = char(app.bcamfullFilename);
                    end
                    roi_finalize_from_video(app.v, roiSummary, pulse_times);
                end
            catch
            end
        end

        function safeStopAndDeleteObjects(app)
            if ~isempty(app.dqIn)
                try
                    stop(app.dqIn);
                catch
                end
            end

            if ~isempty(app.v)
                try
                    if isvalid(app.v)
                        stop(app.v);
                    end
                catch
                end
            end

            if ~isempty(app.v)
                try
                    if isvalid(app.v)
                        delete(app.v);
                    end
                catch
                end
                app.v = [];
            end

            if ~isempty(app.dqIn)
                try
                    delete(app.dqIn);
                catch
                end
                app.dqIn = [];
            end
        end
    end

    % Component initialization
    methods (Access = private)

        % Create UIFigure and components
        function createComponents(app)

            % Create UIFigure and hide until all components are created
            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Position = [100 100 476 242];
            app.UIFigure.Name = 'MATLAB App';

            % Create LoggingControlsLabel
            app.LoggingControlsLabel = uilabel(app.UIFigure);
            app.LoggingControlsLabel.FontSize = 14;
            app.LoggingControlsLabel.FontWeight = 'bold';
            app.LoggingControlsLabel.FontColor = [0.129411764705882 0.129411764705882 0.129411764705882];
            app.LoggingControlsLabel.Position = [15 204 125 22];
            app.LoggingControlsLabel.Text = 'Logging Controls:';

            % Create LoggingDirectoryEditFieldLabel
            app.LoggingDirectoryEditFieldLabel = uilabel(app.UIFigure);
            app.LoggingDirectoryEditFieldLabel.HorizontalAlignment = 'right';
            app.LoggingDirectoryEditFieldLabel.FontColor = [0.129411764705882 0.129411764705882 0.129411764705882];
            app.LoggingDirectoryEditFieldLabel.Position = [13 178 101 22];
            app.LoggingDirectoryEditFieldLabel.Text = 'Logging Directory';

            % Create LoggingDirectoryEditField
            app.LoggingDirectoryEditField = uieditfield(app.UIFigure, 'text');
            app.LoggingDirectoryEditField.CharacterLimits = [1 Inf];
            app.LoggingDirectoryEditField.ValueChangedFcn = createCallbackFcn(app, @LoggingDirectoryEditFieldValueChanged, true);
            app.LoggingDirectoryEditField.FontColor = [0.129411764705882 0.129411764705882 0.129411764705882];
            app.LoggingDirectoryEditField.Placeholder = 'F:\Stim Rig Data';
            app.LoggingDirectoryEditField.Position = [154 178 285 22];
            app.LoggingDirectoryEditField.Value = 'Z:\Vanessa\new_FP_Polina';

            % Create PreviewROIGUIButton
            app.PreviewROIGUIButton = uibutton(app.UIFigure, 'push');
            app.PreviewROIGUIButton.HorizontalAlignment = 'right';
            app.PreviewROIGUIButton.ButtonPushedFcn = createCallbackFcn(app, @PreviewROIGUIButtonPushed, true);
            app.PreviewROIGUIButton.Text = 'Preview ROI GUI';
            app.PreviewROIGUIButton.Position = [143 120 285 22];

            % Create VideoFilenameEditFieldLabel
            app.VideoFilenameEditFieldLabel = uilabel(app.UIFigure);
            app.VideoFilenameEditFieldLabel.HorizontalAlignment = 'right';
            app.VideoFilenameEditFieldLabel.FontColor = [0.129411764705882 0.129411764705882 0.129411764705882];
            app.VideoFilenameEditFieldLabel.Position = [154,146,285,22];
            app.VideoFilenameEditFieldLabel.Text = 'Video Filename';

            % Create VideoFilenameEditField
            app.VideoFilenameEditField = uieditfield(app.UIFigure, 'text');
            app.VideoFilenameEditField.CharacterLimits = [1 Inf];
            app.VideoFilenameEditField.FontColor = [0.129411764705882 0.129411764705882 0.129411764705882];
            app.VideoFilenameEditField.Position = [154 146 285 22];
            app.VideoFilenameEditField.Value = 'tt';

            % Create StatusLabel
            app.StatusLabel = uilabel(app.UIFigure);
            app.StatusLabel.FontWeight = 'bold';
            app.StatusLabel.FontColor = [0.129411764705882 0.129411764705882 0.129411764705882];
            app.StatusLabel.Position = [128 45 41 22];
            app.StatusLabel.Text = 'Status:';

            % Create StartingupLabel
            app.StartingupLabel = uilabel(app.UIFigure);
            app.StartingupLabel.HorizontalAlignment = 'right';
            app.StartingupLabel.FontColor = [0.129411764705882 0.129411764705882 0.129411764705882];
            app.StartingupLabel.Position = [209 45 151 22];
            app.StartingupLabel.Text = 'Starting up...';

            % Create TimeStartedLabel
            app.TimeStartedLabel = uilabel(app.UIFigure);
            app.TimeStartedLabel.FontWeight = 'bold';
            app.TimeStartedLabel.FontColor = [0.129411764705882 0.129411764705882 0.129411764705882];
            app.TimeStartedLabel.Position = [128 25 82 22];
            app.TimeStartedLabel.Text = 'Time Started:';

            % Create NALabel_2
            app.NALabel_2 = uilabel(app.UIFigure);
            app.NALabel_2.HorizontalAlignment = 'right';
            app.NALabel_2.FontColor = [0.129411764705882 0.129411764705882 0.129411764705882];
            app.NALabel_2.Enable = 'off';
            app.NALabel_2.Position = [129 24 231 22];
            app.NALabel_2.Text = 'N/A';

            % Create StartExperimentButton
            app.StartExperimentButton = uibutton(app.UIFigure, 'state');
            app.StartExperimentButton.ValueChangedFcn = createCallbackFcn(app, @StartExperimentButtonValueChanged, true);
            app.StartExperimentButton.Text = 'Start Experiment';
            app.StartExperimentButton.BackgroundColor = [0.7804 0.749 1];
            app.StartExperimentButton.FontSize = 14;
            app.StartExperimentButton.FontWeight = 'bold';
            app.StartExperimentButton.FontColor = [0.129411764705882 0.129411764705882 0.129411764705882];
            app.StartExperimentButton.Position = [129 71 231 47];

            % Create TransCoordsFileEditFieldLabel
            app.TransCoordsFileEditFieldLabel = uilabel(app.UIFigure);
            app.TransCoordsFileEditFieldLabel.HorizontalAlignment = 'right';
            app.TransCoordsFileEditFieldLabel.Position = [280 256 102 22];
            app.TransCoordsFileEditFieldLabel.Text = 'Trans. Coords File';

            % Create TransCoordsFileEditField
            app.TransCoordsFileEditField = uieditfield(app.UIFigure, 'text');
            app.TransCoordsFileEditField.CharacterLimits = [5 Inf];
            app.TransCoordsFileEditField.ValueChangedFcn = createCallbackFcn(app, @TransCoordsFileEditFieldValueChanged, true);
            app.TransCoordsFileEditField.Placeholder = 'TranslatedCoords_020426.mat';
            app.TransCoordsFileEditField.Position = [420 256 212 22];
            app.TransCoordsFileEditField.Value = 'TranslatedCoords_020426.mat';


            % Show the figure after all components are created
            app.UIFigure.Visible = 'on';
        end
    end

    % App creation and deletion
    methods (Access = public)

        % Construct app
        function app = ExperimentalGUI_TCNoStim_exported

            % Create UIFigure and components
            createComponents(app)

            % Register the app with App Designer
            registerApp(app, app.UIFigure)

            % Execute the startup function
            runStartupFcn(app, @startupFcn)

            if nargout == 0
                clear app
            end
        end

        function outPath = pickLatestFile(~, appDir, pattern, fallbackValue)
            files = dir(fullfile(appDir, pattern));
            files = files(~[files.isdir]);
            if ~isempty(files)
                [~, idx] = max([files.datenum]);
                outPath = files(idx).name;
                return;
            end

            fallbackPath = char(fallbackValue);
            [~, nameOnly, extOnly] = fileparts(fallbackPath);
            if ~isempty(nameOnly)
                outPath = [nameOnly extOnly];
            else
                outPath = fallbackPath;
            end
        end
        
        function configureDefaultCalibrationFiles(app, appDir)
            app.TransCoordsFileEditField.Placeholder = 'TranslatedCoords_*.mat';
            %app.CalMtxFileEditField.Placeholder = 'cal_mtx_*.mat';
            %app.LaserIntensitiesFileEditField.Placeholder = 'lsr_ints_*.mat';

            app.TransCoordsFileEditField.Value = app.pickLatestFile(appDir, 'TranslatedCoords_*.mat', app.TransCoordsFileEditField.Value);
            %app.CalMtxFileEditField.Value = app.pickLatestFile(appDir, 'cal_mtx_*.mat', app.CalMtxFileEditField.Value);
            %app.LaserIntensitiesFileEditField.Value = app.pickLatestFile(appDir, 'lsr_ints_*.mat', app.LaserIntensitiesFileEditField.Value);
        end

        % Value changed function: TransCoordsFileEditField
        function TransCoordsFileEditFieldValueChanged(app, ~)
            appDir = fileparts(mfilename('fullpath'));
            [resolved, displayPath] = app.resolveFileInput(appDir, app.TransCoordsFileEditField.Value);
            if isempty(resolved)
                app.TransCoordsFileEditField.Value = "file does not exist!";
            else
                app.TransCoordsFileEditField.Value = displayPath;
            end
        end

        function PreviewROIGUIButtonPushed(app, ~)
            if app.StartExperimentButton.Value
                errordlg('Stop the experiment before launching ROI preview.', 'Preview Unavailable');
                return;
            end
            if ~isempty(app.previewFig)
                try
                    if ishghandle(app.previewFig)
                        figure(app.previewFig);
                        app.StartingupLabel.Text = 'Preview already open';
                        return;
                    end
                catch
                end
            end
            if ~isempty(app.previewVid)
                try
                    if isvalid(app.previewVid)
                        app.StartingupLabel.Text = 'Preview already open';
                        return;
                    end
                catch
                end
            end
            if ~app.canLaunchPreview()
                return;
            end

            app.PreviewROIGUIButton.Enable = 'off';
            app.StartingupLabel.Text = 'Launching ROI preview...';
            drawnow

            try
                app.startROIPreview();
                app.StartingupLabel.Text = 'Idle';
            catch ME
                app.stopROIPreview();
                app.StartingupLabel.Text = 'Idle';
                errordlg(sprintf('ROI preview failed:\n%s', ME.message), 'Preview Error');
            end
            app.PreviewROIGUIButton.Enable = 'on';
        end

        function tf = canLaunchPreview(app)
            tf = false;
            appDir = fileparts(mfilename('fullpath'));
            [transCoordsPath, transCoordsDisplay] = app.resolveFileInput(appDir, app.TransCoordsFileEditField.Value);
            if isempty(transCoordsPath)
                errordlg('Translated coordinates file is missing or invalid.', 'Preview Unavailable');
                return;
            end
            app.TransCoordsFileEditField.Value = transCoordsDisplay;

            tf = true;
        end

        function startROIPreview(app)
            appDir = fileparts(mfilename('fullpath'));
            [transCoordsPath, transCoordsDisplay] = app.resolveFileInput(appDir, app.TransCoordsFileEditField.Value);
            if isempty(transCoordsPath)
                error('Translated coordinates file is missing or invalid.');
            end
            app.TransCoordsFileEditField.Value = transCoordsDisplay;
            data = load(transCoordsPath, 'translated_coords');
            if ~isfield(data, 'translated_coords') || size(data.translated_coords, 2) < 3
                error('Translated coordinates file must contain translated_coords(:,1:3).');
            end
            roiCircles = data.translated_coords(:, 1:3);
            app.previewVid = videoinput("hamamatsu", 1, "MONO16_BIN2x2_1152x1152_Fast");
            app.previewVid.ROIPosition = [0 160 576 238] * 2;

            srcPreview = getselectedsource(app.previewVid);
            srcPreview.OutputTriggerKindOpt3 = "exposure";
            srcPreview.OutputTriggerPolarityOpt3 = "positive";
            srcPreview.ExposureTime = 0.0125; %round(1 / app.FrameRate, 4);
            disp('previewing vid')

            app.previewVid.TriggerRepeat = 0;
            app.previewVid.FramesPerTrigger = Inf;
            triggerconfig(app.previewVid, 'immediate');
            app.previewVid.LoggingMode = 'memory';

            roi_attach_to_video(app.previewVid, roiCircles, struct( ...
                'EnableLogging', false, ...
                'CallbackBatchFrames', 4, ...
                'StrictNoDrop', false, ...
                'PrintFPSPeriod', 2.0));

            start(app.previewVid);
            app.previewFig = roi_stream_gui(app.previewVid, struct('PlotWindowSec', 30, ...
                'UpdatePeriod', 0.5, 'ImagePeriod', 0.25));
            set(app.previewFig, 'CloseRequestFcn', @(src, evt)app.onPreviewFigureClose(src, evt));
        end

        function onPreviewFigureClose(app, src, ~)
            if nargin >= 2 && ishghandle(src)
                try
                    set(src, 'CloseRequestFcn', '');
                catch
                end
                try
                    tmr = getappdata(src, 'roi_gui_timer');
                    if isa(tmr, 'timer') && isvalid(tmr)
                        stop(tmr);
                        delete(tmr);
                    end
                catch
                end
                try
                    delete(src);
                catch
                end
            end
            if ~isempty(app.previewFig) && isequal(src, app.previewFig)
                app.previewFig = [];
            end
            app.stopROIPreview();
        end

        function stopROIPreview(app)
            if ~isempty(app.previewFig)
                try
                    if ishghandle(app.previewFig)
                        try
                            tmr = getappdata(app.previewFig, 'roi_gui_timer');
                            if isa(tmr, 'timer') && isvalid(tmr)
                                stop(tmr);
                                delete(tmr);
                            end
                        catch
                        end
                        delete(app.previewFig);
                    end
                catch
                end
                app.previewFig = [];
            end

            if ~isempty(app.previewVid)
                try
                    if isvalid(app.previewVid)
                        try
                            stop(app.previewVid);
                        catch
                        end
                        delete(app.previewVid);
                    end
                catch
                end
                app.previewVid = [];
            end
        end

        function [outPath, displayPath] = resolveFileInput(app, appDir, inputPath)
            p = char(inputPath);
            if isfile(p)
                outPath = p;
                displayPath = app.localDisplayPath(appDir, outPath);
                return;
            end

            p2 = fullfile(appDir, p);
            if isfile(p2)
                outPath = p2;
                displayPath = app.localDisplayPath(appDir, outPath);
                return;
            end

            outPath = '';
            displayPath = '';
        end

        function displayPath = localDisplayPath(~, appDir, absOrRelPath)
            p = char(absOrRelPath);
            prefix = [char(appDir) filesep];
            if startsWith(p, prefix)
                displayPath = p(numel(prefix) + 1:end);
            else
                displayPath = p;
            end
        end



        % Code that executes before app deletion
        function delete(app)

            % Delete UIFigure when app is deleted
            delete(app.UIFigure)
        end
    end
end
