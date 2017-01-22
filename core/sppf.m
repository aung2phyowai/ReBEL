function [estimate, ParticleFilterDS, pNoise, oNoise] = sppf(ParticleFilterDS, pNoise, oNoise, obs, U1, U2, InferenceDS)

% SPPF  Sigma-Point Particle Filter.
%
%   This hybrid particle filter uses a sigma-point Kalman filter (SRUKF or SRCDKF) for proposal distribution generation
%   and is an extension of the original "Unscented Particle Filter" of Van der Merwe, De Freitas & Doucet.
%
%   [estimate, ParticleFilterDS, pNoise, oNoise] = sppf(ParticleFilterDS, pNoise, oNoise, obs, U1, U2, InferenceDS)
%
%   This filter assumes the following standard state-space model:
%
%     x(k) = ffun[x(k-1),v(k-1),U1(k-1)]
%     y(k) = hfun[x(k),n(k),U2(k)]
%
%   where x is the system state, v the process noise, n the observation noise, u1 the exogenous input to the state
%   transition function, u2 the exogenous input to the state observation function and y the noisy observation of the
%   system.
%
%   INPUT
%         ParticleFilterDS     Particle filter data structure. (see field definitions below)
%         pNoise               (NoiseDS) process noise data structure
%         oNoise               (NoiseDS) observation noise data structure
%         obs                  noisy observations starting at time k ( y(k),y(k+1),...,y(k+N-1) )
%         U1                   exogenous input to state transition function starting at time k-1 ( u1(k-1),u1(k),...,u1(k+N-2) )
%         U2                   exogenous input to state observation function starting at time k  ( u2(k),u2(k+1),...,u2(k+N-1) )
%         InferenceDS          Inference data structure generated by GENINFDS function.
%
%   OUTPUT
%         estimate             State estimate generated from posterior distribution of state given all observation. Type of
%                              estimate is specified by InferenceDS.estimateType
%         ParticleFilterDS     Updated Particle filter data structure. Contains set of particles as well as their corresponding
%                              weights.
%         pNoise               process noise data structure     (possibly updated)
%         oNoise               observation noise data structure (possibly updated)
%
%   ParticleFilterDS fields:
%         .N                   (scalar) number of particles
%         .particles           (statedim-by-N matrix) particle mean buffer
%         .particlesCov        (statedim-by-statedim-by-N matrix) particle covariance buffer (Cholesky factors)
%         .pNoise              (NoiseDS) process noise data structure for SPKF based proposal generation
%         .oNoise              (NoiseDS) observation noise data structure for SPKF based proposal generation
%         .weights             (1-by-N r-vector) particle weights
%
%   Required InferenceDS fields:
%         .spkfType            (string) Type of SPKF to use (srukf or srcdkf).
%         .estimateType        (string) Estimate type : 'mean', 'mode', etc.
%         .resampleThreshold   (scalar) If the ratio of the 'effective particle set size' to the total number of particles
%                                       drop below this threshold  i.e.  (N_efective/N) < resampleThreshold
%                                       the particles will be resampled.  (N_efective is always less than or equal to N)
%
%   NOTE : All covariances are assumed to be of type 'sqrt', i.e. Cholesky factors.
%
%   See also
%   PF, SRUKF, SRCDKF
%   Copyright (c) Oregon Health & Science University (2006)
%
%   This file is part of the ReBEL Toolkit. The ReBEL Toolkit is available free for
%   academic use only (see included license file) and can be obtained from
%   http://choosh.csee.ogi.edu/rebel/.  Businesses wishing to obtain a copy of the
%   software should contact rebel@csee.ogi.edu for commercial licensing information.
%
%   See LICENSE (which should be part of the main toolkit distribution) for more
%   detail.

%=============================================================================================
if (nargin ~= 7) error(' [ sppf ] Not enough input arguments.'); end

%--------------------------------------------------------------------------------------------------

Xdim  = InferenceDS.statedim;                            % extract state dimension
Odim  = InferenceDS.obsdim;                              % extract observation dimension
U1dim = InferenceDS.U1dim;                               % extract exogenous input 1 dimension
U2dim = InferenceDS.U2dim;                               % extract exogenous input 2 dimension
Vdim  = InferenceDS.Vdim;                                % extract process noise dimension
Ndim  = InferenceDS.Ndim;                                % extract observation noise dimension

N  = ParticleFilterDS.N;                      % number of particles
x  = ParticleFilterDS.particles;              % copy particle mean buffer
Sx = ParticleFilterDS.particlesCov;           % copy particle covariance buffer
pNoiseSPKF = ParticleFilterDS.pNoise;         % copy SPKF process noise data structure
oNoiseSPKF = ParticleFilterDS.oNoise;         % copy SPKF observation noise data structure
weights    = ParticleFilterDS.weights;        % particle weights
St         = round(N*InferenceDS.resampleThreshold);   % resample threshold

onoise = zeros(InferenceDS.Ndim,N);

normWeights = cvecrep(1/N,N);

NOV = size(obs,2);                                       % number of input vectors

if (U1dim==0), UU1=zeros(0,N); end
if (U2dim==0), UU2=zeros(0,N); end

estimate   = zeros(Xdim,NOV);

SxPred  = zeros(Xdim,Xdim,N);                     % setup buffers
xNew    = zeros(Xdim,N);
xPred   = zeros(Xdim,N);

ones_numP = ones(N,1);
ones_Xdim = ones(1,Xdim);

proposal = zeros(1,N);

normfact = (2*pi)^(Xdim/2);


for j=1:NOV,
%---------------------------------------------------------------------------

    OBStemp = obs(:,j);                % inline cvecrep
    OBS = OBStemp(:,ones_numP);

    if U1dim
      Utemp = U1(:,j);
      UU1 = Utemp(:,ones_numP);        % inline cvecrep
    end
    if U2dim
      Utemp = U2(:,j);
      UU2 = Utemp(:,ones_numP);        % inline cvecrep
    end


    %-----------------------------------------------------------------------
    % TIME UPDATE

    randBuf = randn(Xdim,N);

    switch InferenceDS.spkfType
    case 'srukf'
        for k=1:N,
            [xNew(:,k), SxPred(:,:,k), pNoiseSPKF, oNoiseSPKF, intvarDS] = srukf(x(:,k), Sx(:,:,k), pNoiseSPKF, oNoiseSPKF, ...
                                                                        obs(:,j), UU1(:,k), UU2(:,k), InferenceDS);

            xPred(:,k) = xNew(:,k) + SxPred(:,:,k)*randBuf(:,k);
        end
    case 'srcdkf'
        for k=1:N,
            [xNew(:,k), SxPred(:,:,k), pNoiseSPKF, oNoiseSPKF, intvarDS] = srcdkf(x(:,k), Sx(:,:,k), pNoiseSPKF, oNoiseSPKF, ...
                                                                        obs(:,j), UU1(:,k), UU2(:,k), InferenceDS);
            xPred(:,k) = xNew(:,k) + SxPred(:,:,k)*randBuf(:,k);
        end
    otherwise
        error(' [ sppf ] Unknown SPKF type.');
    end

    %-----------------------------------------------------------------------
    % EVALUATE IMPORTANCE WEIGHTS


    % calculate transition prior for each particle (in log domain)
    prior = InferenceDS.prior( InferenceDS, xPred, x, UU1, pNoise) + 1e-99;

    % calculate observation likelihood for each particle (in log domain)
    likelihood = InferenceDS.likelihood( InferenceDS, OBS, xPred, UU2, oNoise) + 1e-99;

    difX = xPred - xNew;


    for k=1:N,
        cholFact = SxPred(:,:,k);
        foo = cholFact \ difX(:,k);
        proposal(k) = exp(-0.5*foo'*foo) / abs(normfact*prod(diag(cholFact))) + 1e-99;
        weights(k) = weights(k) * likelihood(k) * prior(k) / proposal(k);
    end


if (0)
figure(20);
subplot(411)
stem(prior);
ylabel('prior');
subplot(412);
stem(likelihood);
ylabel('likelihood');
subplot(413);
stem(proposal);
ylabel('proposal');
subplot(414);
stem(weights);
ylabel('weights');
drawnow
end

    weights = weights / sum(weights);

    %-----------------------------------------------------------------------
    % CALCULATE ESTIMATE

    switch InferenceDS.estimateType

    case 'mean'
        muFoo = sum(weights(ones_Xdim,:).*xPred,2);
        estimate(:,j) = muFoo;          % expected mean

    otherwise
        error(' [ sppf ] Unknown estimate type.');

    end


    %-----------------------------------------------------------------------
    % RESAMPLE

    S = 1/sum(weights.^2);     % calculate effective particle set size

    if (S < St)                  % resample if S is below threshold
        outIndex  = residualresample(1:N,weights);
        x = xPred(:,outIndex);
        for k=1:N,
            Sx(:,:,k) = SxPred(:,:,outIndex(k));
        end
        weights = normWeights;
    else
        x  = xPred;
        Sx = SxPred;
    end



    if pNoise.adaptMethod switch InferenceDS.inftype
    %---------------------- UPDATE PROCESS NOISE SOURCE IF NEEDED --------------------------------------------
    case 'parameter'  %--- parameter estimation
        switch pNoise.adaptMethod
        case 'anneal'
            pNoise.cov = diag(max(pNoise.adaptParams(1) * diag(pNoise.cov) , pNoise.adaptParams(2)));
        otherwise
            error(' [ sppf ]unknown process noise adaptation method!');
        end

    case 'joint'  %--- joint estimation
        idx = pNoise.idxArr(end,:); % get indexs of parameter block of combo noise source
        idxRange=idx(1):idx(2);
        switch pNoise.adaptMethod
        case 'anneal'
            pNoise.cov(idxRange,idxRange) = diag(max(pNoise.adaptParams(1) * diag(pNoise.cov(idxRange,idxRange)), pNoise.adaptParams(2)));
        otherwise
            error(' [ sppf ]unknown process noise adaptation method!');
        end
        pNoise.noiseSources{pNoise.N}.cov = pNoise.cov(idxRange,idxRange);

    %--------------------------------------------------------------------------------------------------
    end; end

%--------------------------------------------------------------------------
end     %.. loop over input vectors


ParticleFilterDS.particles    = x;
ParticleFilterDS.particlesCov = Sx;
ParticleFilterDS.weights      = weights;
ParticleFilterDS.pNoise       = pNoiseSPKF;
ParticleFilterDS.oNoise       = oNoiseSPKF;