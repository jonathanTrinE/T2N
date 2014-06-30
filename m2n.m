function [out, minterf,params,tree] = m2n(tree,params,neuron,path,options)
% function m2n ("Matlab to Neuron") to generate and execute a .hoc-file in NEURON
% with the parameters in the vector <params> and <neuron>;
% The output-file(s) of the NEURON function are read by cn and transferred
% into the output variable out
% Second and third argument are optional; use {} to leave out the second argument.
% 'readyflag' is reserved for checking if neuron has finished
% openNeuron [0]: option to open the command window of NEURON (set to '1'; useful for debugging)
% don't use 'load_file("nrngui.hoc")' in the NEURON-procedure if you don't want the NEURON-menue to
% open (and to get the focus --> extremely anyoing...);
%
% neuron.connect = 
% neuron.play =  {node , 'param', {tvec},{vec},continbool};
% neuron.APCount= {node, thresh};
%
% options:
%   -d Debug mode (NEURON is opened and some parameters are set)
%   -q quiet mode -> suppress output
%   -cl cluster mode -> files are prepared to be executed on a cluster.
%   -f  force cluster to run neuron directly without qsub
%                       Automatic run is not executed and output files are only read if copied back
%
% This code is based on an idea of Johannes Kasper, a former group-member
% in the morphological modelling lab Frankfurt.
%
% Copyright by marcel.beining@gmail.com, April 2014

% check trees are correctly inside one cell
if nargin < 1 || isempty(tree)
    errordlg('No tree specified in input')
    return
end
if iscell(tree) && iscell(tree{1})
    tree = tree{1};
elseif isstruct(tree)
    tree = {tree};
end

if nargin < 4 || isempty(path)
    path = regexprep(pwd,'\\','/');
else
    path = regexprep(path,'\\','/');
end
if strcmpi(path(end),'\')
   path = path(1:end-1); 
end
if strfind(options,'-cl')
    nrn_path = params.server.clpath;
    if ~isfield(params.server,'walltime') || numel(params.server.walltime) ~=3
        params.server.walltime = [0 30 0];
        warndlg('Server walltime not specified correctly (1 by 3 vector in params.server.walltime). Walltime set to 30 minutes');
    end
else
    nrn_path = path;
end

if nargin < 5 || isempty(options)
    options = '';
end
if strfind(options,'-d')
    debug = 1;
else
    debug = 0;
end
%% initialize basic variables
numcell = numel(tree);
noutfiles = 0;
readfiles = cell(0);
orderchanged = false;
skiprun = false;
changed = struct('morph',0,'stim',1,'basic',1,'lib',1,'rec',1,'play',1,'mech',1,'syn',1,'con',1);


%%%%%%%%%%%%%%%%%%% CONFIGURATION %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


interf_file = 'neuron_runthis.hoc'; % the file which will be written

%% check other input

if nargin < 2 || isempty(params)
    if debug == 1
        %% individual params structure for debug
        params.openNeuron = true;
        params.nseg = 'dlambda';
        params.tstop = 200;
        params.dt = 0.025;
        params.accuracy = 0;
        params.custom = {};
        params.changed = changed;
        params.prerun = false;
        
    else
        params = [];
    end
end
if isfield(params,'neuronpath')
    neuronpath = params.neuronpath;
else
    neuronpath = 'C:/nrn73w64/bin64/nrniv.exe';  % change neuron path if necessary
end

if strfind(options,'-cl') 
    
    if ~isfield(params,'server')
    errordlg('No access data provided for Cluster server. Please specify in params.server')
    return
    
    else
        if isfield(params.server,'connect')
           
        else
            if exist('ganymed-ssh2-build250/ganymed-ssh2-build250.jar','file')
                javaaddpath(which('ganymed-ssh2-build250/ganymed-ssh2-build250.jar'));
            else
                try
                    sshfrommatlabinstall(1)
                catch
                    errordlg('Could not find the ganymed ssh zip file')
                    return
                end
            end
            params.server.connect = sshfrommatlab(params.server.user,params.server.host,params.server.pw);
        end
       if ~isfield(params.server,'clpath')
%            params.server.clpath = '~';
%            warndlg('No Path on the Server specified. Root folder will be used')
            errordlg('No Path on Server specified')
            return
       end
    end
end


if exist(neuronpath,'file') ~= 2
    errordlg(sprintf('No NEURON software found under "%s"\nPlease correct the path in cn.m',neuronpath));
end

if isfield(params,'exchfolder')
    exchfolder = fullfile(path,params.exchfolder);
    if strfind(options,'-cl')
        nrn_exchfolder = fullfile(params.server.clpath,params.exchfolder);
    else
        nrn_exchfolder = exchfolder;
    end
else
    exchfolder = fullfile(path,'m2n_exchange');
    if strfind(options,'-cl')
        nrn_exchfolder = fullfile(params.server.clpath,'m2n_exchange');
    else
        nrn_exchfolder = exchfolder;
    end
end

nrn_exchfolder = regexprep(nrn_exchfolder,'\\','/');
%  if strfind(options,'-cl')
%      nrn_exchfolder = regexprep(nrn_exchfolder,'\\','/');
% %      sshfrommatlabissue(params.server.connect,sprintf('mkdir -p %s',cl_exchfolder))
%  end

if ~isfield(params,'openNeuron')
    params.openNeuron = false;
end
if ~isfield(params,'nseg') || strcmpi(params.nseg,'d_lambda')
    params.nseg = 'dlambda';
end
if ~isfield(params,'tstart')
    params.tstart = 0;
end
if ~isfield(params,'tstop')
    params.tstop = 200;
end
if ~isfield(params,'dt')
    params.dt = 0.025;
end
if ~isfield(params,'accuracy')
    params.accuracy = 0;
end
if ~isfield(params,'custom')
    params.custom = {};
end
if ~isfield(params,'skiprun')
    params.skiprun = false;
end
if ~isfield(params,'changed')
    params.changed = changed;
elseif ~isempty(setdiff(fieldnames(changed),fieldnames(params.changed)))
    fld = fieldnames(changed);
    for f = 1:numel(fld)
       if ~isfield(params.changed,fld{f})
           params.changed.(fld{f}) = 1;
       end
    end
end
if isfield(params,'morphfolder')
    morphfolder = fullfile(path,params.morphfolder);
else
    morphfolder = exchfolder;
end

if strfind(options,'-cl')
    if isfield(params,'morphfolder')
        nrn_morphfolder = fullfile(params.server.clpath,params.morphfolder);
    else
        nrn_morphfolder = nrn_exchfolder;
    end

    sshfrommatlabissue(params.server.connect,sprintf('mkdir -p %s',nrn_morphfolder));
else
    nrn_morphfolder = morphfolder;
end
nrn_morphfolder = regexprep(nrn_morphfolder,'\\','/');

if ~exist(morphfolder,'file')
   mkdir(morphfolder);
   params.changed.morph = 1;
elseif ~exist(fullfile(exchfolder,'init_cells.hoc'),'file')
    params.changed.morph = 1;
end
if ~isfield(params,'prerun')
    params.prerun = false;
end
if ~isfield(params,'access')
    params.access = [find(~cellfun(@(x) isfield(x,'artificial'),tree),1,'first') 1];      % std accessing first non-artificial tree at node 1
end


if strfind(options,'-q')
    params.openNeuron = 0;
end

if nargin < 3 || isempty(neuron)
    if debug == 1
        %% individual input structure for debug
        neuron.stim{5} = [5 100 50 5]; % node del dur amp
        neuron.record{1} = {20:40 , 'v';50 , 'v'};
%         neuron.record{1}{(1:numel(tree{1}.X),1} = (1:numel(tree{1}.X))'
%         neuron.record{1}{(1:numel(tree{1}.X),2} = repmat({'v'},[numel(tree{1}.X) 1])
        neuron.record{5} = {5 , 'i_pas'; 300 , 'v'};
        neuron.APCount{5} = [3,-40]; % cell(1,nummcell); % {node, tresh}  vector is always recorded...
    else
        warndlg('No input about what to do were given! Standard is to only record voltage at node 1')
        neuron.record{1} = {1 , 'v'};   %standard is to record voltage at soma
    end
end


% delete the readyflag if it exists
if exist(exchfolder,'dir') == 0
    mkdir(exchfolder);
end
if exist(fullfile(exchfolder,'readyflag'),'file')
    delete(fullfile(exchfolder,'readyflag'))
end
if strfind(options,'-cl')
    [params.server.connect] = sshfrommatlabissue(params.server.connect,sprintf('rm -rf %s',nrn_exchfolder));
    [params.server.connect] = sshfrommatlabissue(params.server.connect,sprintf('mkdir %s',nrn_exchfolder));
end

badchars = 0;
minterf = cell(numcell,1);
if strfind(options,'-d')
    tim = tic;
end
for t=1:numel(tree)     % make neuron templates from trees and save/get minterface file
    artflag = false;
    if ~isfield(tree{t},'artificial')
        [tree{t}, order] = sort_tree(tree{t},'-LO');
        if ~all(order==sort(order))
            orderchanged = true;
        end
    else
        artflag = true;
    end
    if isfield(params,'tname') && ischar(params.tname) && ~isempty(params.tname)
        tname = params.tname;
        tflag = true;
    elseif artflag && ~isfield(tree{t},'name')
        tname = tree{t}.artificial;
        tflag = true;
    elseif isfield(tree{t},'name')
        tname = tree{t}.name;
        tflag = false;
    else
        tname = 'Tree';
        tflag = true;
    end
    if any(strfind(tname,'%'))
        badchars = badchars +numel(strfind(tname,'%'));
        tname(strfind(tname,'%')) = [];
    end
    if any(strfind(tname,'.'))
        badchars = badchars +numel(strfind(tname,'.'));
        tname(strfind(tname,'.')) = '_';
    end
    
    tname = strcat('cell_',tname);
    if tflag
        tname = sprintf('%s_%d%d',tname,floor(t/10),rem(t,10));
    end

    neuron.cellIDs{t} = tname;  % save tree names as cellIDs for neuron
if strfind(options,'-cl')
    [params.server.connect, answer] = sshfrommatlabissue(params.server.connect,sprintf('ls %s/%s.hoc',nrn_morphfolder,tname));
    fchk =  ~isempty(answer{1});
else
    fchk = exist(fullfile(morphfolder,sprintf('%s.hoc',tname)),'file');
end
    
    if params.changed.morph || fchk == 0     % if morphology does not already exists
        oname = tname;
        [tname, nix, minterf{t}] = neuron_template_tree (tree{t}, fullfile(morphfolder,sprintf('%s.hoc',tname)), [], '-m');
        if strfind(options,'-cl')   %transfer files to server
              params.server.connect = sftpfrommatlab(params.server.connect,fullfile(morphfolder,sprintf('%s.hoc',oname)),sprintf('%s/%s.hoc',nrn_morphfolder,oname));
              pause(0.1)
              params.server.connect = sftpfrommatlab(params.server.connect,fullfile(morphfolder,sprintf('%s_minterf.dat',oname)),sprintf('%s/%s_minterf.dat',nrn_morphfolder,oname));
              pause(0.1)
              params.server.connect = sftpfrommatlab(params.server.connect,fullfile(morphfolder,sprintf('%s_minterf.mat',oname)),sprintf('%s/%s_minterf.mat',nrn_morphfolder,oname));
        end
    else
        minterf{t} = load(fullfile(morphfolder,sprintf('%s_minterf.dat',tname)));
    end
    if ~artflag
        if numel(neuron.mech) >= t
            mech = neuron.mech{t};
        else
            mech = [];
        end
        minterf{t} = make_nseg(tree{t},minterf{t},params,mech);
    end
end
if badchars > 0
%     warndlg(sprintf('Caution! %d bad chars had to be removed or replaced from the tree names since they cause writing errors! Please be sure to not use "%%" and "." in the names',badchars),'Bad characters removed');
end
if strfind(options,'-d')
    tim = toc(tim);
    fprintf(sprintf('Tree writing time: %g min %.2f sec\n',floor(tim/60),rem(tim,60)))
end

%% define some output parameters...commented out, instead load tvec from neuron to have exact ts (also necessary for cvode)
% % out.t = params.tstart:params.dt:params.tstop;
% % this is unfortunately necessary to let Matlab have the same tvec size as
% % NEURON, since NEURON produces roundoff errors during long runs
% out.t = NaN(params.tstop/params.dt+1,1);
% out.t(1) = params.tstart;
% ind = 2;
% flag=false;
% while 1
%     if out.t(ind-1) + params.dt <= params.tstop
%         out.t(ind) = out.t(ind-1) + params.dt;
%         ind = ind +1;
%     else
%         if isnan(out.t(end))    % this is due roundoff error -> one entry less..
%             out.t(end) = [];
%             flag = true;
%         end
%         break
%     end
% end
% if isempty(strfind(options,'-r'))       % make nice numbers if not intended to use correct t values
%     out.t = params.tstart:params.dt:params.tstop-(flag*params.dt);
% end

%% start writing hoc file
%% write interface hoc
if strfind(options,'-d')
    tim = tic;
end
if params.changed.basic || params.changed.lib || params.changed.morph     %rewrite only if something has changed influencing this file
    nfile = fopen(fullfile(exchfolder,interf_file) ,'wt');   %open resulting hoc file in write modus
    
    fprintf(nfile,'// ***** This is a NEURON hoc file automatically created by the Matlab-NEURON interface algorithm. *****\n');
    fprintf(nfile,'// ***** Copyright by Marcel Beining and Johannes Kasper, Clinical Neuroanatomy, Goethe University Frankfurt*****\n\n');
    %initialize variables in NEURON
    fprintf(nfile,'// General variables: i, CELLINDEX, debug_mode, accuracy\n');
    
    fprintf(nfile,'// ***** Initialize Variables *****\n');
    fprintf(nfile,'objref f\n');
    fprintf(nfile,'objref nil,strf,tvec,cell,cellList,syn,synList,stim,stimList,con,conList,rec,recList,playt,playtList,play,playList,APCrec,APCrecList,APC,APCList,APCcon,APCconList \n cellList = new List() \n stimList = new List() \n synList = new List() \n conList = new List() \n recList = new List()\n playtList = new List()\n playList = new List()\n APCList = new List()\n APCrecList = new List()\n APCconList = new List()\n');%[',numel(tree),']\n'  ;
    
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Define some basic parameters *****\n');
    fprintf(nfile,sprintf('debug_mode = %d\n',debug) );
    if isfield(params,'accuracy')
        fprintf(nfile,sprintf('accuracy = %d\n',params.accuracy) );
    else
        fprintf(nfile,'accuracy = 0\n' );
    end
    fprintf(nfile,'strf = new StringFunctions()\n');
    fprintf(nfile,sprintf('tvec = new Vector()\ntvec.indgen(%f,%f,%f)\n',params.tstart,params.tstop,params.dt));
    fprintf(nfile,'f = new File()\n');      %create a new filehandle
    fprintf(nfile,sprintf('f.wopen("%s/tvec.dat")\n',nrn_exchfolder)  );  % open file for this time vector with write perm.
    fprintf(nfile,sprintf('tvec.printf(f,"%%%%-20.10g")\n') );%"%%%%-20.10g")\n', c ) );    % print the data of the vector into the file
    fprintf(nfile,'f.close()\n');
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Load standard libraries *****\n');
    if isfield(params,'nrnmech')
        if iscell(params.nrnmech)
            for c = 1:numel(params.nrnmech)
                fprintf(nfile,sprintf('nrn_load_dll("lib_mech/%s")\n',params.nrnmech{c}));
            end
        else
            fprintf(nfile,sprintf('nrn_load_dll("lib_mech/%s")\n',params.nrnmech));
        end
    else
       fprintf(nfile,'nrn_load_dll("lib_mech/nrnmech.dll")\n');
    end
    if params.openNeuron
        fprintf(nfile,'load_file("nrngui.hoc")\n');     % load the NEURON GUI
    else
        fprintf(nfile,'load_file("stdgui.hoc")\n');     % ony load other standard procedures
    end
    fprintf(nfile, sprintf('xopen("%s/lib_genroutines/fixnseg.hoc")\n',nrn_path) );
    fprintf(nfile, sprintf('xopen("%s/lib_genroutines/genroutines.hoc")\n',nrn_path) );
    fprintf(nfile, sprintf('xopen("%s/lib_genroutines/pasroutines.hoc")\n',nrn_path) );
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Load custom libraries *****\n');
    if ~isempty(params.custom)
        for c = 1:size(params.custom,1)
            if strcmpi(params.custom{c,2},'start') && exist(fullfile(nrn_path,'lib_customroutines',params.custom{c,1}),'file')
                fprintf(nfile,sprintf('load_file("%s/lib_customroutines/%s")\n',nrn_path,params.custom{c,1}));
            end
        end
    end
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Load cell morphologies and create artificial cells *****\n');
    fprintf(nfile,sprintf('xopen("%s/init_cells.hoc")\n',nrn_exchfolder) );
%     fprintf(nfile,'\n\n');
%     fprintf(nfile,'// ***** Load passive model *****\n');
%     fprintf(nfile,sprintf('xopen("%s/init_pas.hoc")\n',nrn_exchfolder) );
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Load mechanisms *****\n');
    fprintf(nfile,sprintf('xopen("%s/init_mech.hoc")\n',nrn_exchfolder) );
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Place synapses *****\n');
    fprintf(nfile,sprintf('xopen("%s/init_syn.hoc")\n',nrn_exchfolder) );
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Define Connections *****\n');
    fprintf(nfile,sprintf('xopen("%s/init_con.hoc")\n',nrn_exchfolder) );
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Place stimulations *****\n');
    fprintf(nfile,sprintf('xopen("%s/init_stim.hoc")\n',nrn_exchfolder) );
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Define recording sites *****\n');
    fprintf(nfile,sprintf('xopen("%s/init_rec.hoc")\n',nrn_exchfolder) );
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Define vector play sites *****\n');
    fprintf(nfile,sprintf('xopen("%s/init_play.hoc")\n',nrn_exchfolder) );

    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Last settings *****\n');
    fprintf(nfile,'addsurf_spines()\n');
    fprintf(nfile,sprintf('tstart = %f\n',params.tstart));   %set params.tstart
    fprintf(nfile,sprintf('tstop = %f + %f //advances one more step due to roundoff errors for high tstops\n',params.tstop,params.dt));   %set params.tstop
    fprintf(nfile,sprintf('dt = %f\n',params.dt));         % set params.dt
    fprintf(nfile,sprintf('steps_per_ms = %f\n',1/params.dt));         % set steps per ms to avois changing dt on reinit
    if isfield(params,'v_init')
        fprintf(nfile,sprintf('v_init = %f\n',params.v_init)); 
    end
    fprintf(nfile,sprintf('prerun = %d\n',params.prerun));
    if numel(params.access) > 1 % if there is any non-artificial cell defined
        fprintf(nfile,sprintf('access cellList.o(%d).allregobj.o(%d).sec\n',params.access(1)-1,minterf{1}(params.access(2),2)) );
    end
    fprintf(nfile,'make_nseg()\n');
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Include custom code *****\n');
    if ~isempty(params.custom)
        for c = 1:size(params.custom,1)
            if strcmpi(params.custom{c,2},'mid') && exist(fullfile(path,'lib_customroutines',params.custom{c,1}),'file')
                fprintf(nfile,sprintf('load_file("%s/lib_customroutines/%s")\n',path,params.custom{c,1}));
%                 if size(params.custom(c),2) > 2 && strcmpi(params.custom{c,3},'skiprun')
%                     skiprun = true;
%                 end
            end
        end
    end
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Run NEURON *****\n');

    if ~params.skiprun
        fprintf(nfile,'init()\n');  % this needs to be modified later since v_init might be restarted
        fprintf(nfile,'run()\n');         % directly run the simulation
    else
        fprintf(nfile,'// Run is skipped due to custom code\n');
    end
    
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Write Data to Files *****\n');
    fprintf(nfile,sprintf('xopen("%s/save_rec.hoc")\n',nrn_exchfolder) );

    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Include further custom code *****\n');
    if ~isempty(params.custom)
        for c = 1:size(params.custom,1)
            if strcmpi(params.custom{c,2},'end') && exist(fullfile(path,'lib_customroutines',params.custom{c,1}),'file')
                fprintf(nfile,sprintf('load_file("%s/lib_customroutines/%s")\n',path,params.custom{c,1}));
            end
        end
    end
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Make Matlab notice end of simulation *****\n');
    fprintf(nfile,'f = new File()\n');       %create a new filehandle
    fprintf(nfile,sprintf('f.wopen("%s")\n',strcat(nrn_exchfolder,'/readyflag') ) );       % create the readyflag file
    fprintf(nfile,'f.close()\n');   % close the filehandle
    if ~params.openNeuron
        fprintf(nfile,'quit()\n');  % exit NEURON if it was defined so in the parameters
    end
    
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// *-*-*-*-* END *-*-*-*-*\n');
    
    fclose(nfile);
end
%% write init_cells.hoc
if params.changed.morph     %rewrite only if something has changed influencing this file
    ofile = fopen(fullfile(exchfolder,'init_cells.hoc') ,'wt');   %open morph hoc file in write modus
    fprintf(ofile,'\n\n');
    fprintf(ofile,'// ***** Load cell morphologiy templates and create artificial cells *****\n');
    for t = 1:numel(tree)
        % load templates generated by neuron_template_tree, create one
        % instance of them and add them to the cellList

        fprintf(ofile,sprintf('xopen("%s/%s.hoc")\n',nrn_morphfolder,neuron.cellIDs{t}) );
        fprintf(ofile, sprintf('cell = new %s()\n', neuron.cellIDs{t}) );
        fprintf(ofile, 'cellList.append(cell)\n');

    end
    fprintf(ofile, 'objref cell\n');
    
    fprintf(ofile,'\n\n');
    fprintf(ofile,'// ***** Define nseg for all cells *****\n');
    fprintf(ofile, 'proc make_nseg() {\n');
    fprintf(ofile, 'for CELLINDEX = 0, cellList.count -1 {\n');
    fprintf(ofile, 'if (cellList.o(CELLINDEX).is_artificial == 0) {\n');
%     fprintf(ofile, 'if (strf.is_artificial(cellList.o(CELLINDEX)) == 0) {\n');
    if isfield(params,'nseg') && isnumeric(params.nseg)
        fprintf(ofile, 'forsec cellList.o(CELLINDEX).allreg {\n');
        fprintf(ofile, sprintf('nseg = %f}\n}\n}\n',round(params.nseg)) );
        if rem(round(params.nseg),2) == 0
            warndlg('nseg is not odd! Please reconsider nseg');
        end
    elseif isfield(params,'nseg') && strcmpi(params.nseg,'dlambda')
        fprintf(ofile, 'geom_nseg()\n}\n}\n}\n');
    else
        fprintf(ofile, '// No nseg specified!!!\n}\n}\n}\n');
        warndlg('nseg has not been specified (correctly?)! nseg is not set!')
    end
    fclose(ofile);
end
% if params.changed.pas || params.changed.morph     %rewrite only if something has changed influencing this file
%     ofile = fopen(fullfile(exchfolder,'init_pas.hoc') ,'wt');   %open morph hoc file in write modus
%     fprintf(ofile,'\n\n');
%     fprintf(ofile,'// ***** Insert passive parameters *****\n');
%     if isfield(neuron,'pas')
%         for t = 1:numel(tree)
%             if numel(neuron.pas) >= t && ~isempty(neuron.pas{t}) && ~isfield(tree{t},'artificial')    % if passive properties are defined for this tree
%                 if numel(neuron.pas{t}) > 2     % check if passive model should be inserted
%                     str='insert pas';
%                 else
%                     str ='';
%                 end
%                 if ~isnan(neuron.pas{t}(1))
%                     str = sprintf('%s\ncm = %g',str,neuron.pas{t}(1));
%                 end
%                 if ~isnan(neuron.pas{t}(2))
%                     str = sprintf('%s\nRa = %g',str,neuron.pas{t}(2));
%                 end
%                 if ~isnan(neuron.pas{t}(3))
%                     str = sprintf('%s\ng_pas = %g',str,neuron.pas{t}(3));
%                 end
%                 if ~isnan(neuron.pas{t}(4))
%                     str = sprintf('%s\ne_pas = %g}\n',str,neuron.pas{t}(4));
%                     %                     str = sprintf('%s\nv = %g\n',str,neuron.pas{t}(4));
%                     %                     %was used to make v = e_pas but doesnt work with
%                     %                     finitialize or fcurrent it seems
%                 else
%                     str = sprintf('%s}\n',str);
%                 end
%                 
%                 fprintf(ofile,sprintf('forsec cellList.o(%d).allreg {%s',t-1,str) );    %insert standard passive model in all sections
%             end
%         end
%     end
% 
%     fclose(ofile);
% end
if params.changed.mech || params.changed.morph     %rewrite only if something has changed influencing this file
    ofile = fopen(fullfile(exchfolder,'init_mech.hoc') ,'wt');   %open morph hoc file in write modus
    fprintf(ofile,'\n\n');
    fprintf(ofile,'// ***** Insert mechanisms *****\n');
    if isfield(neuron,'mech')
        for t = 1:numel(tree)
            if numel(neuron.mech) >= t && ~isempty(neuron.mech{t})   && ~isfield(tree{t},'artificial')    % if a mechanism is defined for this tree
                if isstruct(neuron.mech{t})          % input must be a structure
                    fields = fieldnames(neuron.mech{t});
                else
                    continue
                end
                
                if any(strcmpi(fields,'all'))
                    str = sprintf('forsec cellList.o(%d).allreg {\n',t-1);   %neuron:go through this region
                    mechs = fieldnames(neuron.mech{t}.all);                % mechanism names are the fieldnames in the structure
                    for m = 1:numel(mechs)      % loop through mechanisms
                        str = sprintf('%sinsert %s\n',str,mechs{m});        % neuron:insert this mechanism
%                         if size(neuron.mech{t}.all.(mechs{m}),2) == 2     %if parameter definition is no mby2 cell array,rearrange
%                             mechpars = neuron.mech{t}.(regs{r}).(mechs{m});
%                         else
%                             resh = size(neuron.mech{t}.all.(mechs{m}),2)/2;
%                             mechpars = reshape(neuron.mech{t}.all.(mechs{m}),2,resh)';
%                         end
                        if ~isempty(neuron.mech{t}.all.(mechs{m}))
                            mechpar = fieldnames(neuron.mech{t}.all.(mechs{m}));
                            for p = 1:numel(mechpar)  % loop through mechanism parameters
                                if strcmpi(mechpar{p},'cm') || strcmpi(mechpar{p},'Ra') || ~isempty(strfind(mechs{m},'_ion'))        %if mechanism is an ion or passive cm/Ra, leave out mechansim suffix
                                    str = sprintf('%s%s = %g\n',str,mechpar{p},neuron.mech{t}.all.(mechs{m}).(mechpar{p}));   %neuron: define values
                                else
                                    str = sprintf('%s%s_%s = %g\n',str,mechpar{p},mechs{m},neuron.mech{t}.all.(mechs{m}).(mechpar{p}));   %neuron: define values
                                end
                            end
                        end
                    end
                    fprintf(ofile,sprintf('%s}\n\n',str));
                end
                
                uR = unique(tree{t}.R); % Region indices that exist in tree
                if ~isempty(intersect(tree{t}.rnames(uR),fields)) %isstruct(neuron.mech{t}.(fields{1}))  %check if mechanism was defined dependent on existent region
                    regs = fields;  %if yes (some of) the input are the regions 
                    regs = intersect(tree{t}.rnames(uR),regs);  % only use those region names which are existent in tree
                    for r = 1 : numel(regs)
                        str = sprintf('forsec cellList.o(%d).reg%s {\n',t-1,regs{r});   %neuron:go through this region
                        mechs = fieldnames(neuron.mech{t}.(regs{r}));                % mechanism names are the fieldnames in the structure
                        for m = 1:numel(mechs)      % loop through mechanisms
                            str = sprintf('%sinsert %s\n',str,mechs{m});        % neuron:insert this mechanism
                             
%                             if size(neuron.mech{t}.(regs{r}).(mechs{m}),2) == 2     %if parameter definition is no mby2 cell array,rearrange
%                                 mechpars = neuron.mech{t}.(regs{r}).(mechs{m});
%                             else
%                                 resh = size(neuron.mech{t}.(regs{r}).(mechs{m}),2)/2;
%                                 mechpars = reshape(neuron.mech{t}.(regs{r}).(mechs{m}),2,resh)';
%                             end
                            if ~isempty(neuron.mech{t}.(regs{r}).(mechs{m}))
                                mechpar = fieldnames(neuron.mech{t}.(regs{r}).(mechs{m}));
                                for p = 1:numel(mechpar)  % loop through mechanism parameters
                                    if strcmpi(mechpar{p},'cm') || strcmpi(mechpar{p},'Ra') || ~isempty(strfind(mechpar{p},'_ion'))        %if mechanism is an ion or passive Rm/Ra, leave out mechansim suffix
                                        str = sprintf('%s%s = %g\n',str,mechpar{p},neuron.mech{t}.(regs{r}).(mechs{m}).(mechpar{p}));   %neuron: define values
                                    else
                                        str = sprintf('%s%s_%s = %g\n',str,mechpar{p},mechs{m},neuron.mech{t}.(regs{r}).(mechs{m}).(mechpar{p}));   %neuron: define values
                                    end
                                end
                            end
                        end
                        fprintf(ofile,sprintf('%s}\n\n',str));
                    end
                end
                
%                 % now go through the rest
%                 mechs = fields;
%                 mechs = setdiff(mechs,tree{t}.rnames); %delete the Region definitions
%                 mechs = setdiff(mechs,'all'); %delete the Region definitions   % everything remaining should be unused regions..
%                 %CAUTION if regions have been defined which are not in the
%                 %tree
%                 if ~isempty(mechs)
%                     flag=false;
%                     for m = 1:numel(mechs) %loop through all (putative) mechanisms
%                         if isstruct(neuron.mech{t}.(mechs{m}))
%                             continue %workaround to avoid not existent regions, everything else must be a mechanism!
%                         end
%                         if ~flag   %if it's the first time the loop works,write the forsec argument in neuron to go through all sections
%                             str = sprintf('forsec cellList.o(%d).allreg {\n',t-1);
%                             flag = true;
%                         end
%                         str = sprintf('%sinsert %s\n',str,mechs{m});   %neuron: insert this mechanism
%                         
% %                         if size(neuron.mech{t}.(mechs{m}),2) == 2     %if parameter definition is no mby2 cell array,rearrange
% %                             mechpars = neuron.mech{t}.(mechs{m});
% %                         else
% %                             resh = size(neuron.mech{t}.(mechs{m}),2)/2;
% %                             mechpars = reshape(neuron.mech{t}.(mechs{m}),resh,2)';
% %                         end
%                         if ~isempty(neuron.mech{t}.(mechs{m}))
%                             mechpar = fieldnames(neuron.mech{t}.(mechs{m}));
%                             for p = 1:numel(mechpar)         %loop through all mechnism parameters
%                                 if strfind(mechs{m},'_ion')        %if mechanism is an ion, leave out mechanism suffix
%                                     str = sprintf('%s%s = %g\n',str,mechpar{p},neuron.mech{t}.(mechs{m}).(mechpar{p}));
%                                 else
%                                     str = sprintf('%s%s_%s = %g\n',str,mechpar{p},mechs{m},neuron.mech{t}.(mechs{m}).(mechpar{p}));
%                                 end
%                             end
%                         end
%                     end
%                     fprintf(ofile,sprintf('%s}\n\n',str));      %write the string and close section loop
%                 end
            end
        end
        if isfield(params,'celsius')
            fprintf(ofile,'\n\nobjref q10\nq10 = new Temperature()\n' ) ;
            fprintf(ofile,sprintf('q10.correct(%g)\n\n',params.celsius) ) ;
        end
    end
    fclose(ofile);          %close file 
end

if params.changed.syn || params.changed.morph     %rewrite only if something has changed influencing this file
    ofile = fopen(fullfile(exchfolder,'init_syn.hoc') ,'wt');   %open morph hoc file in write modus
    fprintf(ofile,'\n\n');
    fprintf(ofile,'// ***** Place synapses or other point processes *****\n');
    if isfield(neuron,'syn')
        synnum = zeros(numel(tree),1);
        for t = 1:numel(tree)
            if numel(neuron.syn) >= t && ~isempty(neuron.syn{t})   && ~isfield(tree{t},'artificial')    % if synapses are defined for this tree
                % this adds synapses specified...maybe a function
                % distributing them will do it better later
                for s = 1:size(neuron.syn{t},1)
                    inode = find(minterf{t}(:,1) == neuron.syn{t}{s,2},1,'first');    %find the index of the node in minterf
                    fprintf(ofile,sprintf('cellList.o(%d).allregobj.o(%d).sec',t-1,minterf{t}(inode,2) ) );    % corresponding section of node
                    fprintf(ofile,sprintf('{syn = new %s(%f)\n',neuron.syn{t}{s,1},minterf{t}(inode,3) ) );  % new syn
                    if numel(neuron.syn{t}) > 2 && isstruct(neuron.syn{t}{s,3})          % input must be a structure
                        fields = fieldnames(neuron.syn{t}{s,3});
                        for f =1:numel(fields)
                           fprintf(ofile,sprintf('syn.%s = %g\n',fields{f},neuron.syn{t}{s,3}.(fields{f})));
                        end
                    end
                    fprintf(ofile,'}\n');
                    fprintf(ofile,'synList.append(syn)\n' );  %append syn to synList
                    synnum(t) = synnum(t) +1;
                end
            end
        end
        fprintf(ofile, 'objref syn\n');
    end
    fclose(ofile);
else            % synnum has to be redefined anyways
    if isfield(neuron,'syn')
        synnum = zeros(numel(tree),1);
        for t = 1:numel(tree)
            if numel(neuron.syn) >= t && ~isempty(neuron.syn{t})   && ~isfield(tree{t},'artificial')    % if synapses are defined for this tree
                for s = 1:size(neuron.syn{t},1)
                    synnum(t) = synnum(t) +1;
                end
            end
        end
    end
end


if params.changed.con || params.changed.morph     %rewrite only if something has changed influencing this file
    ofile = fopen(fullfile(exchfolder,'init_con.hoc') ,'wt');   %open morph hoc file in write modus
    fprintf(ofile,'\n\n');
    fprintf(ofile,'// ***** Define Connections *****\n');
    if isfield(neuron,'con')
        % should have look like: {source(node or point process), what to
        % watch, target, threshold, delay, weight}
        for c = 1:size(neuron.con,1)
            str = '';
            nodeflag = false;
            switch neuron.con{c,1}
               
                case 'cell'
                    if ischar(neuron.con{c,2})
                        t = str2double(neuron.con{c,2});
                    else
                        t = neuron.con{c,2};
                    end
                    if ~isempty(t) && isfield(tree{t},'artificial')
%                         if ~isempty(neuron.con{c,3}) && ischar(neuron.con{c,3})
%                             str = sprintf('%scon = new NetCon(&cellList.o(%d)(%s),',str,t-1,neuron.con{c,3});
%                         else
                            str = sprintf('%scon = new NetCon(cellList.o(%d).cell,',str,t-1);
%                         end
                    else
                        str = sprintf('%scon = new NetCon(nil,',str);
                    end
                case 'node'
                    expr = regexp(neuron.con{c,2},'\.','split');
                    t = str2double(expr{1});
                    inode = str2double(expr{2});
                    inode = find(minterf{t}(:,1) == inode,1,'first');    %find the index of the node in minterf
                    if ~isempty(neuron.con{c,3}) && ~isnan(neuron.con{c,3})
                        str = sprintf('%scellList.o(%d).allregobj.o(%d).sec {con = new NetCon(&%s(%f),',str,t-1,minterf{t}(inode,2),neuron.con{c,3},minterf{t}(inode,3));
                    else
                        str = sprintf('%scellList.o(%d).allregobj.o(%d).sec {con = new NetCon(&v(%f),',str,t-1,minterf{t}(inode,2),minterf{t}(inode,3));
                    end
                    nodeflag = true;
                case 'syn'
                    expr = regexp(neuron.con{c,2},'\.','split');
                    t = str2double(expr{1});
                    s = str2double(expr{2});
%                     if ~isempty(neuron.con{c,3}) && ischar(neuron.con{c,3})
%                         str = sprintf('%scon = new NetCon(&synList.o(%d)(%s),',str,sum(synnum(1:t-1))+s-1,neuron.con{c,3});
%                     else
                        str = sprintf('%scon = new NetCon(synList.o(%d),',str,sum(synnum(1:t-1))+s-1);
%                     end
                    
                otherwise
                    str = sprintf('%scon = new NetCon(nil,',str);
            end
            
            switch neuron.con{c,4}
                case 'cell'
                    if ischar(neuron.con{c,2})
                        t = str2double(neuron.con{c,5});
                    else
                        t = neuron.con{c,5};
                    end
                    if ~isempty(t) && isfield(tree{t},'artificial')
                            str = sprintf('%scellList.o(%d).cell',str,t-1);
                    else
                        str = sprintf('%snil',str);
                    end
                case 'syn'
                    expr = regexp(neuron.con{c,5},'\.','split');
                    t = str2double(expr{1});
                    s = str2double(expr{2});
                    str = sprintf('%ssynList.o(%d)',str,sum(synnum(1:t-1))+s-1);
                otherwise
                    str = sprintf('%snil',str);
                    
            end
            if size(neuron.con(c,:),2) >= 8 && numel(cat(1,neuron.con{c,6:8})) == 3
                str = sprintf('%s,%g,%g,%g)\n',str,neuron.con{c,6},neuron.con{c,7},neuron.con{c,8});   %threshold , delay,weight
            else
                str = sprintf('%s)\n',str);
            end
                                
            str = sprintf('%sconList.append(con)',str);  %append con to conList
            if nodeflag
                str = sprintf('%s}\n',str);
            else
                str = sprintf('%s\n',str);
            end
            fprintf(ofile,str);  % new connection
            

            
        end
        fprintf(ofile, 'objref con\n');
%         for t = 1:numel(tree)
%             if numel(neuron.con) >= t && ~isempty(neuron.con{t})     % if a connection is defined for this tree
%             end
%         end
    end
    fprintf(ofile,'\n\n');
    fclose(ofile);
end


%% write init_stim.hoc
if params.changed.stim || params.changed.morph     %rewrite only if something has changed influencing this file
    ofile = fopen(fullfile(exchfolder,'init_stim.hoc') ,'wt');   %open stim hoc file in write modus
    fprintf(ofile,'\n\n');
    fprintf(ofile,'// ***** Place stimulations *****\n');
    if isfield(neuron,'stim')
        stimnum = zeros(numel(tree),1);
        for t = 1:numel(tree)
            if numel(neuron.stim) >= t && ~isempty(neuron.stim{t}) && ~isfield(tree{t},'artificial')   % if a stimulation is defined for this tree
                for s = 1: size(neuron.stim{t},1)
                    inode = find(minterf{t}(:,1) == neuron.stim{t}{s,1},1,'first');    %find the index of the node in minterf
                    fprintf(ofile,sprintf('cellList.o(%d).allregobj.o(%d).sec',t-1,minterf{t}(inode,2) ) );    % corresponding section of node
                    switch neuron.stim{t}{s,2}      % if SEClamp and VClamp dur and amp would be handled equally this could be simplified much more =/
                        case 'IClamp'
                            fprintf(ofile,sprintf('{stim = new IClamp(%f)\n',minterf{t}(inode,4) ) );  % new stim
                            fields = fieldnames(neuron.stim{t}{s,3});
                            if any(strcmp(fields,'times'))
                                times = sprintf('%f,',neuron.stim{t}{s,3}.times);
                                times = times(1:end-1);
                                amps = sprintf('%f,',neuron.stim{t}{s,3}.amp);
                                amps = amps(1:end-1);
                                
                                fprintf(ofile,'playt = new Vector()\n');
                                fprintf(ofile,sprintf('playt.append(%s)\n',times));
                                fprintf(ofile,'play = new Vector()\n');
                                fprintf(ofile,sprintf('play.append(%s)\n',amps));
                                fprintf(ofile,'play.play(&stim.amp,playt)\n');
                                fprintf(ofile,'stim.dur = 1e15\n');
                                fprintf(ofile,'stim.del = -1e4\n');
                                
                                fprintf(ofile,'playtList.append(playt)\n');
                                fprintf(ofile,'playList.append(play)\n');
                                fprintf(ofile, 'objref play\n');
                                fprintf(ofile, 'objref playt\n');
                            else
                                for f = 1:numel(fields)
                                    fprintf(ofile,sprintf('stim.%s = %f \n',fields{f},neuron.stim{t}{s,3}.(fields{f})));
                                end
                            end
                            %                             fprintf(ofile,sprintf('stim.del = %f \nstim.dur = %f \nstim.amp = %f }\n',neuron.stim{t}{s,3:4} ) );    %define stim properties as described in neuron.stim
                        case 'VClamp'
                            fprintf(ofile,sprintf('{stim = new VClamp(%f)\n',minterf{t}(inode,4) ) );  % new stim
                            fields = fieldnames(neuron.stim{t}{s,3});   % get parameter names
                            for f = 1:numel(fields)     % loop through all parameters and write them in hoc
                                if any(strcmpi(fields{f},{'dur','amp'}))    % for dur and amp, there are multiple values
                                    for n = 1:numel(neuron.stim{t}{s,3}.(fields{f}))
                                         fprintf(ofile,sprintf('stim.%s[%d] = %f \n',fields{f},n-1,neuron.stim{t}{s,3}.(fields{f})(n)));
                                    end
                                else
                                    fprintf(ofile,sprintf('stim.%s = %f \n',fields{f},neuron.stim{t}{s,3}.(fields{f})));
                                end
                            end
%                             dur = neuron.stim{t}{s,3};
%                             amp = neuron.stim{t}{s,4};
%                             switch numel(dur)   %adapt duration if not all 3 dur values are given
%                                 case 1
%                                     dur = [0,dur,0];
%                                 case 2
%                                     dur = [dur(1),dur(2),0];
%                             end
%                             switch numel(amp)   % adapt amp if not all 3 amp values are given
%                                 case 1
%                                     amp = [params.v_init,amp,params.v_init];
%                                 case 2
%                                     amp = [params.v_init,amp(1),amp(2)];
%                             end
% 
%                             fprintf(ofile,sprintf('stim.dur[0] = %f \nstim.dur[1] = %f \nstim.dur[2] = %f \nstim.amp[0] = %f \nstim.amp[1] = %f \nstim.amp[2] = %f }\n',dur,amp ) );    %define stim properties as described in neuron.stim

                        case 'SEClamp'
                            fprintf(ofile,sprintf('{stim = new SEClamp(%f)\n',minterf{t}(inode,4) ) );  % new stim
                            fields = fieldnames(neuron.stim{t}{s,3});   % get parameter names
                            for f = 1:numel(fields)     % loop through all parameters and write them in hoc
                                if any(strcmpi(fields{f},{'dur','amp'}))    % for dur and amp, there are multiple values
                                    for n = 1:numel(neuron.stim{t}{s,3}.(fields{f}))
                                        fprintf(ofile,sprintf('stim.%s%d = %f \n',fields{f},n,neuron.stim{t}{s,3}.(fields{f})(n)));
                                    end
                                else
                                    fprintf(ofile,sprintf('stim.%s = %f \n',fields{f},neuron.stim{t}{s,3}.(fields{f})));
                                end
                            end
                    end
                    fprintf(ofile,'} \n stimList.append(stim)\n' );  %append stim to stimList
                    stimnum(t) = stimnum(t) +1;
                end
                fprintf(ofile,'\n');
            end
            
        end
        fprintf(ofile, 'objref stim\n');
    end
    fclose(ofile);
else            % stimnum has to be redefined anyways
    if isfield(neuron,'stim')
        stimnum = zeros(numel(tree),1);
        for t = 1:numel(tree)
            if numel(neuron.stim) >= t && ~isempty(neuron.stim{t})   && ~isfield(tree{t},'artificial')    % if synapses are defined for this tree
                for s = 1:size(neuron.stim{t},1)
                    stimnum(t) = stimnum(t) +1;
                end
            end
        end
    end
end
%% write init_rec.hoc
if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
    ofile = fopen(fullfile(exchfolder,'init_rec.hoc') ,'wt');   %open record hoc file in write modus
    fprintf(ofile,'\n\n');
    fprintf(ofile,'// ***** Define recording sites *****\n');
end
if isfield(neuron,'record')
    
    for t = 1:numel(tree)
        if numel(neuron.record) >= t && ~isempty(neuron.record{t})   && ~isfield(tree{t},'artificial')   % if a recording site was defined for  this tree
            for r = 1: size(neuron.record{t},1)
                inode = zeros(numel(neuron.record{t}{r,1}),1);
                for n = 1:numel(neuron.record{t}{r,1})
                    inode(n) = find(minterf{t}(:,1) == neuron.record{t}{r,1}(n),1,'first');    %find the index of the node in minterf
                end
                realrecs = unique(minterf{t}(inode,[2,4]),'rows');
                if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
                    for n = 1:size(realrecs,1)
                        %             fprintf(ofile,sprintf('cellList.o(%d).allregobj.o(%d).sec {\n',t-1,minterf{t}(inode,2) ) );
                        fprintf(ofile,sprintf('rec = new Vector(%f)\n',(params.tstop-params.tstart)/params.dt+1 ) );    % create new recording vector
                        if (strcmpi(neuron.record{t}{r,2},'i') || strcmpi(neuron.record{t}{r,2},'icur')) && ~isempty(neuron.stim{t})  %record from electrode, not from cell
                            fprintf(ofile,sprintf('rec.label("%s of %s electrode %d at location %06.4f of section %d of cell %d")\n', neuron.record{t}{r,2} , neuron.stim{t}{neuron.record{t}{r,1},2}, neuron.record{t}{r,1}, minterf{t}(find(minterf{t}(:,1) == neuron.stim{t}{neuron.record{t}{r,1},1},1,'first'),[4 2]) ,t-1) ); % label the vector for plotting
                            fprintf(ofile,sprintf('rec.record(&stimList.o(%d).%s,tvec)\n',sum(stimnum(1:t-1))+n-1, neuron.record{t}{r,2} ) ); % record the parameter x at site y as specified in neuron.record
                        else
                            fprintf(ofile,sprintf('rec.label("%s at location %06.4f of section %d of cell %d")\n', neuron.record{t}{r,2} , realrecs(n,2), realrecs(n,1) ,t-1) ); % label the vector for plotting
                            fprintf(ofile,sprintf('rec.record(&cellList.o(%d).allregobj.o(%d).sec.%s(%f),tvec)\n',t-1,realrecs(n,1), neuron.record{t}{r,2}, realrecs(n,2) ) ); % record the parameter x at site y as specified in neuron.record
                        end
                        fprintf(ofile,'recList.append(rec)\n\n' );  %append recording vector to recList
                        %                     fprintf(ofile,sprintf('rec = new Vector(%f)\n',params.tstop/params.dt ) );    % create new recording vector
                        %                     fprintf(ofile,sprintf('rec.label("%s at node %d of cell %d")\n', neuron.record{t}{r,2} , inode ,t-1) ); % label the vector for plotting
                        %                     fprintf(ofile,sprintf('rec.record(&cellList.o(%d).allregobj.o(%d).sec.%s(%f))\n',t-1,minterf{t}(inode,2), neuron.record{t}{r,2}, minterf{t}(inode,3) ) ); % record the parameter x at site y as specified in neuron.record
                        %                     fprintf(ofile,'recList.append(rec)\n\n' );  %append recording vector to recList
                        %%tempVec = new Vector(params.tstop/params.dt)
                        %%tempVec.record(&v(tempList2.o[i].loc))
                        %%tempList.append(tempVec)
                    end
                end
                neuron.record{t}{r,3} = realrecs;
            end
            if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
                fprintf(ofile,'\n');
            end
        end
    end
    if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
        fprintf(ofile, 'objref rec\n');
    end
end
if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
    fprintf(ofile,'\n\n');
    fprintf(ofile,'// ***** Define APCount sites *****\n');
    if isfield(neuron,'APCount')
        for t = 1:numel(tree)
            if numel(neuron.APCount) >= t && ~isempty(neuron.APCount{t})   % if a recording site was defined for  this tree
                for r = 1: size(neuron.APCount{t},1)
                    % apc.n
                    % apc.time --- ms
                    % apc.record(vector)
                    if ~isfield(tree{t},'artificial')
                        inode = find(minterf{t}(:,1) == neuron.APCount{t}(r,1),1,'first');    %find the index of the node in minterf
                        fprintf(ofile,sprintf('cellList.o(%d).allregobj.o(%d).sec',t-1,minterf{t}(inode,2) ) );    % corresponding section of node
                        fprintf(ofile,sprintf('{APC = new APCount(%f)\n',minterf{t}(inode,3) ) );    % make APCCount at position x
                        fprintf(ofile,sprintf('APC.thresh = %f\n',neuron.APCount{t}(r,2) ) ); % set threshold of APCount [mV]
                        %             if neuron.APCount{t}{r,3}
                    else
                        fprintf(ofile,sprintf('APC = new NetCon(cellList.o(%d).cell,nil,%g,0,5)\n',t-1,neuron.APCount{t}(r,2) ) );    % for art. cells, make netcon with threshold
                    end
                    fprintf(ofile,'APCrec = new Vector()\n');
                    fprintf(ofile,'APCrecList.append(APCrec)\n');
                    fprintf(ofile,'APC.record(APCrecList.o(APCrecList.count()-1))\n');
                    %             end
                    
                    if ~isfield(tree{t},'artificial')
                        fprintf(ofile,'APCList.append(APC)}\n\n' );  %append recording vector to recList
                    else
                        fprintf(ofile,'APCList.append(APC)\n\n' );  %append recording vector to recList
                    end
                end
                fprintf(ofile,'\n');
            end
        end
        fprintf(ofile, 'objref APC\n');
        fprintf(ofile, 'objref APCrec\n');
    end
    fclose(ofile);
end
%% write init_play.hoc
if params.changed.play || params.changed.morph     %rewrite only if something has changed influencing this file
    ofile = fopen(fullfile(exchfolder,'init_play.hoc') ,'wt');   %open record hoc file in write modus
    fprintf(ofile,'\n\n');
    fprintf(ofile,'// ***** Define play sites *****\n');
    if isfield(neuron,'play')
        for t = 1:numel(tree)
            if numel(neuron.play) >= t &&~isempty(neuron.play{t})  && ~isfield(tree{t},'artificial')   % if a playing site was defined for  this tree
                for p = 1: size(neuron.play{t},1)
                    inode = find(minterf{t}(:,1) == neuron.play{t}{p,1},1,'first');    %find the index of the node in minterf
                    fprintf(ofile,sprintf('playt = new Vector(%f)\n',length(neuron.play{t}{p,3}) ) );    % create new playing time vector
                    %a file needs to be created to temporally save the vector so
                    %NEURON can read it in. otherwise it would be necessary to
                    %print the whole vector into the hoc file. alternatively i
                    %could give a file name where the vector lies so it is not
                    %written each time cn is called...
                    f = fopen(sprintf('plt_%s_at_%d_cell_%d.dat', neuron.play{t}{p,2} , inode ,t-1),'w');
                    fprintf(f,'%g ', neuron.play{t}{p,3}(1:end-1));
                    fprintf(f,'%g\n', neuron.play{t}{p,3}(end));
                    fclose(f);
                    fprintf(ofile,'f = new File()');
                    fprintf(ofile,sprintf('f.ropen("plt_%s_at_%d_cell_%d.dat")\n', neuron.play{t}{p,2} , inode ,t-1));  %vector file is opened
                    fprintf(ofile,'playt.scanf(f)');    % file is read into time vector
                    fprintf(ofile,'f.close()');     %file is closed
                    fprintf(ofile,'playtList.append(playt)\n\n' );  %append playing time vector to playtList
                    
                    fprintf(ofile,sprintf('play = new Vector(%f)\n',length(neuron.play{t}{p,4}) ) );    % create new playing vector
                    f = fopen(sprintf('pl_%s_at_%d_cell_%d.dat', neuron.play{t}{p,2} , inode ,t-1),'w');
                    fprintf(f,'%g ', neuron.play{t}{p,4}(1:end-1));
                    fprintf(f,'%g\n', neuron.play{t}{p,4}(end));
                    fclose(f);
                    fprintf(ofile,'f = new File()');
                    fprintf(ofile,sprintf('f.ropen("pl_%s_at_%d_cell_%d.dat")\n', neuron.play{t}{p,2} , inode ,t-1));  %vector file is opened
                    fprintf(ofile,'play.scanf(f)');     % file is read into play vector
                    fprintf(ofile,'f.close()');   %file is closed
                    fprintf(ofile,sprintf('play.label("playing %s at node %d of cell %d")\n', neuron.play{t}{p,2} , inode ,t-1) ); % label the vector for plotting
                    fprintf(ofile,sprintf('play.play(&cellList.o(%d).allregobj.o(%d).sec.%s(%f),playtList.o(playtList.count()-1),%d)\n',t-1,minterf{t}(inode,2), neuron.play{t}{p,2}, minterf{t}(inode,3), neuron.play{t}{p,5} ) ); % play the parameter x at site y as specified in neuron.play
                    fprintf(ofile,'playList.append(play)\n\n' );  %append playing vector to playList
                    
                end
                fprintf(ofile,'\n');
            end
        end
        fprintf(ofile, 'objref playt\n');
        fprintf(ofile, 'objref play\n');
    end
    fclose(ofile);
end

%% write save_rec.hoc
if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
    ofile = fopen(fullfile(exchfolder,'save_rec.hoc') ,'wt');   %open record hoc file in write modus
    fprintf(ofile,'// * Write Recordings to Files *\n');
end
if isfield(neuron,'record')
    out.record = cell(1,numcell);   % initialize output of cn
    c=0;
    for t = 1:numel(tree)
        if numel(neuron.record) >= t && ~isempty(neuron.record{t})  && ~isfield(tree{t},'artificial') 
            for r = 1: size(neuron.record{t},1)
                for n = 1:size(neuron.record{t}{r,3},1)
                    if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
                        fprintf(ofile,'f = new File()\n');      %create a new filehandle
                        fprintf(ofile,sprintf('f.wopen("%s/%s")\n',nrn_exchfolder,sprintf('cell%d_sec%d_loc%06.4f_%s.dat',t-1, neuron.record{t}{r,3}(n,1), neuron.record{t}{r,3}(n,2), neuron.record{t}{r,2} ))  );  % open file for this vector with write perm.
                        fprintf(ofile,sprintf('recList.o(%d).printf(f, "%%%%-20.10g")\n', c ) );    % print the data of the vector into the file
                        fprintf(ofile,'f.close()\n');   %close the filehandle
                    end
                    c= c+1;
                    noutfiles = noutfiles +1;
%                     readfiles{noutfiles} = {sprintf('cell%d_node%d_%s.dat',t-1,neuron.record{t}{r,1},neuron.record{t}{r,2} ) , 'record' ,  t , neuron.record{t}{r,2} ,neuron.record{t}{r,1} };
                    readfiles{noutfiles} = {sprintf('cell%d_sec%d_loc%06.4f_%s.dat',t-1, neuron.record{t}{r,3}(n,1), neuron.record{t}{r,3}(n,2), neuron.record{t}{r,2} ) , 'record' ,  t , neuron.record{t}{r,2} ,neuron.record{t}{r,3}(n,1) ,neuron.record{t}{r,3}(n,2) };
                end
            end
        end
    end
    if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
    fprintf(ofile,'\n');
    end
end
if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
    fprintf(ofile,'// * Write APCounts to Files *\n');
end
if isfield(neuron,'APCount')
    out.APCtimes = cell(1,numcell);   % initialize output of cn
    
    c=0;
    for t = 1:numel(tree)
        if numel(neuron.APCount) >= t && ~isempty(neuron.APCount{t})     % if a recording site was defined for  this tree
            for r = 1: size(neuron.APCount{t},1)
                if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
                    fprintf(ofile,'f = new File()\n');      %create a new filehandle
                    fprintf(ofile,sprintf('f.wopen("%s/%s")\n',nrn_exchfolder,sprintf('cell%d_node%d_APCtimes.dat',t-1,neuron.APCount{t}(r,1) )) );  % open file for this vector with write perm.
                    fprintf(ofile,sprintf('APCrecList.o(%d).printf(f, "%%%%-20.10g")\n', c ) );    % print the data of the vector into the file
                    fprintf(ofile,'f.close()\n');   %close the filehandle
                end
                c= c+1;
                noutfiles = noutfiles +1;
                readfiles{noutfiles} = {sprintf('cell%d_node%d_APCtimes.dat',t-1,neuron.APCount{t}(r,1) ) , 'APCtimes' , t , neuron.APCount{t}(r,1) };
                
            end
            if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
                fprintf(ofile,'\n');
            end
        end
    end
end
if params.changed.rec || params.changed.morph     %rewrite only if something has changed influencing this file
    fclose(ofile);
end

if strfind(options,'-cl') %transfer files to server
    filenames = {interf_file,'init_cells.hoc','init_mech.hoc','init_syn.hoc','init_con.hoc','init_stim.hoc','init_rec.hoc','save_rec.hoc','init_play.hoc'}; %'init_pas.hoc',
    localfilename = cell(0);
    remotefilename = cell(0);
    if params.changed.basic || params.changed.lib || params.changed.morph
        localfilename{end+1} = fullfile(exchfolder,filenames{1});
        remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,filenames{1});
    end
    if params.changed.morph
        localfilename{end+1} = fullfile(exchfolder,filenames{2});
        remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,filenames{2});
    end
%     if params.changed.pas || params.changed.morph
%         localfilename{end+1} = fullfile(exchfolder,filenames{3});
%         remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,filenames{3});
%     end
    if  params.changed.mech || params.changed.morph
        localfilename{end+1} = fullfile(exchfolder,filenames{4});
        remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,filenames{4});
    end
    if params.changed.syn || params.changed.morph
        localfilename{end+1} = fullfile(exchfolder,filenames{5});
        remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,filenames{5});
    end
    if params.changed.con || params.changed.morph
        localfilename{end+1} = fullfile(exchfolder,filenames{6});
        remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,filenames{6});
    end
    if params.changed.stim || params.changed.morph
        localfilename{end+1} = fullfile(exchfolder,filenames{7});
        remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,filenames{7});
    end
    if params.changed.rec || params.changed.morph
        localfilename{end+1} = fullfile(exchfolder,filenames{8});
        remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,filenames{8});
        localfilename{end+1} = fullfile(exchfolder,filenames{9});
        remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,filenames{9});
    end
    if params.changed.play || params.changed.morph
        localfilename{end+1} = fullfile(exchfolder,filenames{10});
        remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,filenames{10});
    end
    if isempty(strfind(options,'-f'))
        %create job
        ofile = fopen(fullfile(exchfolder,'start_nrn.job') ,'wt');
        
        fprintf(ofile,'#!/bin/bash\n');
        fprintf(ofile,'# write standard output to file\n');
        fprintf(ofile,sprintf('#PBS -o simstart_%s.oe\n',regexprep(datestr(now),{' ','\-','\:'},'_')));
        fprintf(ofile,'# calculate for 30 minutes on 5 core, max. 512 MB of RAM per process\n');
        fprintf(ofile,sprintf('#PBS -l walltime=%s,nodes=5,pmem=512m\n',sprintf('%02d:%02d:%02d',params.server.walltime)));
        fprintf(ofile,'# load needed modules \n');
        fprintf(ofile,'module load openmpi/gcc/64/1.3.3\n');
        fprintf(ofile,'# change to path with your executale\n');
        %     fprintf(ofile,sprintf('cd %s\n',nrn_exchfolder));
        fprintf(ofile,'# start your program with mpirun with 5 processes\n');
        fprintf(ofile,sprintf('mpirun -np 5 nrngui -nobanner -nogui -mpi %s/%s \n',nrn_exchfolder,interf_file));
        fclose(ofile);
        localfilename{end+1} = fullfile(exchfolder,'start_nrn.job');
        remotefilename{end+1} = sprintf('%s/%s',nrn_exchfolder,'start_nrn.job');
    end
    params.server.connect = sftpfrommatlab(params.server.connect,localfilename,remotefilename);
end

if strfind(options,'-d')
    tim = toc(tim);
    fprintf(sprintf('HOC writing time: %g min %.2f sec\n',floor(tim/60),rem(tim,60)))
end

%% Execute NEURON
if strfind(options,'-d')
    tim = tic;
end


switch params.openNeuron
    case 1
        opsign = '&'; % execute the program in foreground and hand control to NEURON
    case 0
        opsign = '-c quit() \n exit';  % execute the program iconified
end


% execute the file in neuron:
fname = regexprep(fullfile(exchfolder,interf_file),'\\','/');
result = [];

if strfind(options,'-q')
    if (strfind(options,'-cl'))
        if strfind(options,'-f')
%             [params.server.connect,answer] = sshfrommatlabissue(params.server.connect,sprintf('mpirun -np 5 nrngui -nobanner -nogui -mpi %s/%s \n',nrn_exchfolder,interf_file));
            [params.server.connect,answer] = sshfrommatlabissue(params.server.connect,sprintf('nrngui -nobanner -nogui %s/%s \n',nrn_exchfolder,interf_file));  %!%!%!%!
        else
            [params.server.connect,answer] = sshfrommatlabissue(params.server.connect,sprintf('qsub %s/%s',nrn_exchfolder,'start_nrn.job'));
            fprintf(sprintf('Answer server after submitting: %s\nExtracing Job Id and wait..\n',answer{1}))
        end
    else
        oldpwd = '';
        if ~strcmpi(pwd,path)
            oldpwd = pwd;
            cd(path);
        end
        [status,result] = dos([neuronpath ' -nobanner "' fname '" -c quit() \n exit']); %&,char(13),'exit&']); %nrniv statt neuron
        if ~isempty(oldpwd)
            cd(oldpwd);
        end
    end
else
    if (strfind(options,'-cl'))
        % this is also quiet since no neuron gui was installed...
        if strfind(options,'-f')
            [params.server.connect,answer] = sshfrommatlabissue(params.server.connect,sprintf('mpirun -np 5 nrngui -nobanner -nogui -mpi %s/%s \n',nrn_exchfolder,interf_file));
            
        else
            [params.server.connect,answer] = shfrommatlabissue(params.server.connect,sprintf('qsub %s/%s',nrn_exchfolder,'start_nrn.job'));
            fprintf(sprintf('Answer server after submitting: %s\n',answer{1}))
        end
    else
        oldpwd = '';
        if ~strcmpi(pwd,path)
            oldpwd = pwd;
            cd(path);
        end
        [status,result] = dos([neuronpath ' -nobanner "' fname '" ' opsign]); %&,char(13),'exit&']); %nrniv statt neuron
        if ~isempty(oldpwd)
            cd(oldpwd);
        end
    end
end
if ~isempty(strfind(options,'-cl')) && numel(answer) == 1 && isempty(strfind(options,'-f'))
    str = regexp(answer{1},'[0-9]*','match');
    ncount = cellfun(@numel,str);
    [nix, ind] = max(ncount);
    jobid = str2double(str{ind});
end
%% Receive files from Neuron
if noutfiles > 0 % if output is expected
    % wait for the NEURON process to be finished as indicated by appearance of
    % a file called 'readyflag' in the exchfolder; should be created in the last
    % line of the NEURON program
    r=0;
    if isempty(strfind(options,'-q'))
        display('waiting for NEURON to finish...')
    end
    flag = false;
    while r ~= 1
        if ~isempty(strfind(options,'-cl')) 
            if isempty(strfind(options,'-f'))
                % with direct mpirun matlab waits for command to be finished so there is no need
                % for while loop..
                pause(1);
                [params.server.connect,answer] = sshfrommatlabissue(params.server.connect,sprintf('qstat %d',jobid));
                r = isempty(answer{1});
                if ~r
                    answer = textscan(answer{3},'%*[^QR]%s%*[^QR]');
                    if strcmpi(answer{1},'R')
                        if ~flag
                            display('Simulation is calculated on cluster')
                            if strfind(options,'-d')
                                tim = toc(tim);
                                fprintf(sprintf('Cluster queue wait time: %g min %.2f sec\n',floor(tim/60),rem(tim,60)))
                                tim = tic;  %reset timer to acount for queue wait time
                                flag = true;
                            end
                        end
                        %                     pause((params.server.walltime(1)*60+params.server.walltime(2))*60+params.server.walltime(3))
                    end
                end
                %             [params.server.connect,answer] = sshfrommatlabissue(params.server.connect,sprintf('ls %s/readyflag',nrn_exchfolder));
            else
                r=1;
                oanswer = answer;
            end
        else
            if ~isempty(result) && ~isempty(strfind(result,'error')) || ~isempty(strfind(result,'near line'))
                ret = regexp(result,'\n');
                er =  strfind(result,'error');
                if isempty(er)
                    er = strfind(result,'near line');
                    er = er(1);
                    ind = find(ret < er,1,'last')-1;
                else
                    er = er(1);
                    ind = find(ret < er,1,'last');
                end
                result = result(ret(ind)+1:end);
                errordlg(sprintf('An error occurred during NEURON execution:\n******************************\n%s\n******************************\nDue to that, m2n does not return an output!',result))
                out = [];
                return
            end
            
            r = exist([exchfolder '/readyflag'],'file') == 2;
            pause(0.1);
        end
    end
    if strfind(options,'-cl')
        [params.server.connect,answer] = sshfrommatlabissue(params.server.connect,sprintf('ls %s/readyflag',nrn_exchfolder));
        if isempty(answer)    % then there was an error during executing NEURON
            if strfind(options,'-f')
                errordlg(sprintf('There was an error during NEURON simulation:\n %s.',strcat(oanswer{:})))
            else
                [params.server.connect,answer] = sshfrommatlabissue(params.server.connect,sprintf('ls *e%d*',jobid));
                if ~isempty(answer)
                    % was planned to directly show error but...
                    %                 scptomatlab(params.server.connect,exchfolder,answer{1})
                    %                 f = fopen(fullfile(exchfolder,answer{1}));
                    %                 errfile = textscan(f,'%s','Delimiter','\n');
                    %                 errstr =
                    errordlg(sprintf('There was an error during NEURON simulation. Please refer to cluster output file "%s".',answer{1}))
                end
            end
            return
        end
    end
%     
%         dos('exit');  % exit NEURON if it was defined so in the parameters
%     end
if strfind(options,'-d')
    tim = toc(tim);
    fprintf(sprintf('NEURON execute time: %g min %.2f sec\n',floor(tim/60),rem(tim,60)))
end
if isempty(strfind(options,'-q'))
    display('NEURON finished... loading data...')
end
if strfind(options,'-d')
    tim = tic;
end
if strfind(options,'-cl')
    outputnames = cellfun(@(x) strcat(nrn_exchfolder,'/',x{1}),readfiles,'UniformOutput',0);  % extract filenames
    scptomatlab(params.server.connect,exchfolder,outputnames)
end

% load time vector from NEURON (necessary because of roundoff errors
fn = fullfile(exchfolder,'tvec.dat');
out.t = load(fn,'-ascii');  
            
% load the results:
for f = 1:noutfiles
    fn = fullfile(exchfolder,readfiles{f}{1});
    %         varargout{f} = load(fn,'-ascii');
    switch readfiles{f}{2}
        case 'record'
            readfiles{f}{7} = load(fn,'-ascii');    %temporary loading of file. association is done below
            
            %                 out.(readfiles{f}{2}){readfiles{f}{3}}.(readfiles{f}{4}){readfiles{f}{5}} = load(fn,'-ascii');
        case 'APCtimes'
            out.(readfiles{f}{2}){readfiles{f}{3}}{readfiles{f}{4}} = load(fn,'-ascii');
        otherwise
            errordlg(sprintf('Data "%s" not specified for output',readfiles{f}{2}))
    end
end
if isfield(neuron,'record')
    for t = 1:numel(tree)
        if numel(neuron.record) >= t && ~isempty(neuron.record{t}) && ~isfield(tree{t},'artificial')   % if a recording site was defined for  this tree
            for r = 1: size(neuron.record{t},1)     %go through all set recordings
                %                     inode = zeros(numel(neuron.record{t}{r,1}),1);
                for n = 1:numel(neuron.record{t}{r,1})  %go through all nodes in this defined recording
                    inode = find(minterf{t}(:,1) == neuron.record{t}{r,1}(n),1,'first');    %find the index of the node in minterf
                    %the correct file for this node is searched in the
                    %temporally loaded files and copied
                    onlyrecords = cellfun(@(x) strcmpi(x{2},'record'),readfiles);
                    thisfile = find(cumsum(onlyrecords) == find(cellfun(@(x) strcmpi(x{4},neuron.record{t}{r,2}) & x{3} == t & x{5} == minterf{t}(inode,2) & x{6} == minterf{t}(inode,4) ,readfiles(onlyrecords))),1,'first');
                    out.record{t}.(neuron.record{t}{r,2}){neuron.record{t}{r,1}(n)} = readfiles{thisfile}{7};
                    % alternatively only give pointer and give temp
                    % files as output, too...
                end
                
            end
        end
    end
end
if isempty(strfind(options,'-q'))
    display('data sucessfully loaded')
end
if strfind(options,'-d')
    tim = toc(tim);
    fprintf(sprintf('Data loading time: %g min %.2f sec\n',floor(tim/60),rem(tim,60)))
end
end

if nargout < 3 && orderchanged
%     warndlg('Caution, the node order of some trees had to be changed! Sort your trees with "sort_tree" to obtain the correct results','Node order change!')
end


end

function minterf = make_nseg(tree,minterf,params,mech)       
%does the same as the d_lambda procedure in NEURON
%necessary to find nearest segment which will be calculated
if ischar(params.nseg) && strcmpi(params.nseg,'dlambda')
    dodlambda = 1;
     pl = [0;PL_tree(tree)];     % path length of tree..add zero because neuron_template_tree adds one tiny segment at root
     D =  [0;tree.D]; %.add zero because neuron_template_tree adds one tiny segment at root
    freq = 100;
%     if ~isempty(mech) && all(~isnan(mech))
%         Ra = pas(2);
%         cm = pas(1);
%     else
% 
%     end
    if isfield(params,'d_lambda')
        d_lambda = params.d_lambda;
    else
        
        d_lambda = 0.1;
    end
else
    dodlambda = 0;
end

for sec = 0:max(minterf(:,2))  %go through all sections
    if dodlambda
        secstart = find(minterf(:,2) == sec & minterf(:,3) == 0);
        secend = find(minterf(:,2) == sec & minterf(:,3) == 1);
        secnodestart = minterf(secstart,1);
        secnodestart2 = minterf(secstart+1,1);
        if isfield(mech,tree.rnames{tree.R(secnodestart)}) && isfield(mech.(tree.rnames{tree.R(secnodestart)}),'pas') && all(isfield(mech.(tree.rnames{tree.R(secnodestart)}).pas,{'Ra','cm'}))
            Ra = mech.(tree.rnames{tree.R(secnodestart)}).pas.Ra;
            cm = mech.(tree.rnames{tree.R(secnodestart)}).pas.cm;
        elseif isfield(mech,'all') && isfield(mech.all,'pas') && all(isfield(mech.all.pas,{'Ra','cm'}))
            Ra = mech.all.pas.Ra;
            cm = mech.all.pas.cm;
        else
            %NEURON standard values for Ra and cm
            warndlg(sprintf('Ra or cm of region %s in tree %s not specified',tree.rnames{tree.R(secnodestart)},tree.name),'Ra or cm not specified','replace')
            Ra = 35.4;
            cm = 1;
        end
        secnodeend = minterf(secend,1);
%         a=zeros(numel(tree.X),1)
%         a(secnodestart:secnodeend)=1
%         plot_tree(tree,a)
        L =  pl(secnodeend) - pl(secnodestart); %length of section
        lambda_f = 0;
        %from here same calculation as in fixnseg
        for n = secnodestart2:secnodeend
            if n == secnodestart2   % if lastnode was a branching node it is not in a row with next node.account for that
                lambda_f = lambda_f + (pl(n)-pl(secnodestart))/sqrt(D(secnodestart)+D(n));
            else
                lambda_f = lambda_f + (pl(n)-pl(n-1))/sqrt(D(n-1)+D(n));
            end
        end
        lambda_f = lambda_f * sqrt(2) * 1e-5*sqrt(4*pi*freq*Ra*cm);
        
        if lambda_f == 0
            lambda_f = 1;
        else
            lambda_f = L/lambda_f;
        end
%         fprintf('%g\n',lambda_f)
        nseg = floor((L/(d_lambda*lambda_f)+0.9)/2)*2 + 1;     %!%!%! recheck this in NEURON book
%         fprintf('%g\n',(L/(d_lambda*lambda_f)+0.9))
    else
        nseg = params.nseg;
    end
%     fprintf('%d\n',nseg);
    if isfield(params,'accuracy') && params.accuracy == 1 %triple nseg if accuracy is necessary
        nseg = 3 * nseg;
    end
%     fprintf('%d\n',nseg)
    pos = (2 * (1:nseg) - 1) / (2*nseg);    %calculate positions
    for n = secstart:secend
        [nix,ind] = min(abs(minterf(n,3) - pos));   %find position to node which is closest to next segment location
        minterf(n,4) = pos(ind);                % hier evt ausnahme f�r anfang und ende der section (=0)
    end
end
    
end