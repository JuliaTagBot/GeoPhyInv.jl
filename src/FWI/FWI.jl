__precompile__()

"""
This module defines a type called `Param` that is to be constructed 
before performing 
and kind of inversion.
The following functionality is currently added in this module:
* a simple RTM
* full-waveform inversion
* source and receiver filter inversion
Once a `Param` object is constructed, the following routines update certain fields
of the `Param` after performing the inversion.
* `xfwi!` : updates the initial subsurface models in `Param` using its observed data
* `wfwi!` : updates the source and receiver filters in `Param` using its observed data
"""
module FWI

using Interpolation
using Conv
using Grid
using Misfits
using Inversion
using TimerOutputs
using LinearMaps
using Ipopt

import JuMIT.Models
import JuMIT.Acquisition
import JuMIT.Data
import JuMIT.Coupling
import JuMIT.Fdtd
using Optim, LineSearches
using DistributedArrays
using Calculus


global const to = TimerOutput(); # create a timer object

# modeling types
struct ModFdtd end

struct ModFdtdBorn end

struct ModFdtdHBorn end


"""
FWI Parameters

# Fields

* `mgrid::Grid.M2D` : modelling grid
* `igrid::Grid.M2D` : inversion grid
* `acqsrc::Acquisition.Src` : base source wavelet for modelling data
* `acqgeom::Acquisition.Geom` : acquisition geometry
* `tgrid::Grid.M1D` : 
* `attrib_mod`
* `model_obs` : model used for generating observed data
* `model0` : background velocity model (only used during Born modeling and inversion)
* `parameterization` : a vector of Symbols specifying parameterization of the inversion vector
* `verbose` : print level on STOUT
* `attrib` : synthetic or real

TODO: add an extra attribute for coupling functions inversion and modelling
"""
mutable struct Param{Tattrib_mod, Tdatamisfit}
	"model inversion variable"
	mx::Inversion.X{Float64,1}
	mxm::Inversion.X{Float64,1}
	"forward modelling parameters for"
	paf::Fdtd.Param
	"base source wavelet"
	acqsrc::Acquisition.Src
	"adjoint source functions"
	adjsrc::Acquisition.Src
	"acquisition geometry"
	acqgeom::Acquisition.Geom
	"acquisition geometry for adjoint propagation"
	adjacqgeom::Acquisition.Geom
	"modeling attribute"
	attrib_mod::Tattrib_mod
	"Seismic model on modeling grid"
	modm::Models.Seismic
	"background Seismic model"
	modm0::Models.Seismic
	"Seismic on inversion grid"
	modi::Models.Seismic
	"initialize on this model"
	mod_initial::Models.Seismic
	"prior model on the inversion grid"
	priori::Models.Seismic
	"prior weights on the inversion grid"
	priorw::Models.Seismic
	"gradient Seismic model on modeling grid"
	gmodm::Models.Seismic
	"gradient Seismic on inversion grid"
	gmodi::Models.Seismic
	"parameterization"
	parameterization::Vector{Symbol}
	"model preconditioning"
	mprecon::AbstractArray{Float64,2}
	"compute data misfit"
	paTD::Tdatamisfit
	paminterp::Interpolation.Kernel_2D{Float64}
	verbose::Bool
	"synthetic or field inversion"
	attrib::Symbol
end

struct LS end # just cls inversion

struct LS_prior # cls inversion including prior 
	α::Vector{Float64} # weights
end

function LS_prior()
	return LS_prior([1.0, 0.5])
end

struct Migr end # returns first gradient

struct Migr_fd end # computes first gradient using FD

include("core.jl")
include("prior.jl")

"""
Convert the data `TD` to `Src` after time reversal.
"""
function update_adjsrc!(adjsrc, δdat::Data.TD, adjacqgeom)
	nt=δdat.tgrid.nx
	for i in 1:adjacqgeom.nss
		for j in 1:length(δdat.fields)
			wav=adjsrc.wav[i,j] 
			dat=δdat.d[i,j]
			for ir in 1:δdat.acqgeom.nr[i]
				for it in 1:nt
					@inbounds wav[it,ir]=dat[nt-it+1,ir]
				end
			end
		end
	end
	return nothing
end

function generate_adjsrc(fields, tgrid, adjacqgeom)
	adjsrc=Acquisition.Src_zeros(adjacqgeom, fields, tgrid)
	return adjsrc
end


"""
Constructor for `Param`

# Arguments

* `acqsrc::Acquisition.Src` : source time functions
* `acqgeom::Acquisition.Geom` : acquisition geometry
* `tgrid::Grid.M1D` : modelling time grid
* `attrib_mod::Union{ModFdtd, ModFdtdBorn, ModFdtdHBorn}` : modelling attribute
* `modm::Models.Seismic` : seismic model on modelling mesh 

# Optional Arguments
* `tgrid_obs::Grid.M1D` : time grid for observed data

* `igrid::Grid.M2D=modm.mgrid` : inversion grid if different from the modelling grid, i.e., `modm.mgrid`
* `igrid_interp_scheme` : interpolation scheme
  * `=:B1` linear 
  * `=:B2` second order 
* `mprecon_factor::Float64=1` : factor to control model preconditioner, always greater than 1
  * `=1` means the preconditioning is switched off
  * `>1` means the preconditioning is switched on, larger the mprecon_factor, stronger the applied preconditioner becomes
* `dobs::Data.TD` : observed data
* `dprecon::Data.TD=Data.TD_ones(1,dobs.tgrid,dobs.acqgeom)` : data preconditioning, defaults to one 
* `tlagssf_fracs=0.0` : maximum lagtime of unknown source filter
* `tlagrf_fracs=0.0` : maximum lagtime of unknown receiver filter
* `acqsrc_obs::Acquisition.Src=acqsrc` : source wavelets to generate *observed data*; can be different from `acqsrc`
* `modm_obs::Models.Seismic=modm` : actual seismic model to generate *observed data*
* `modm0::Models.Seismic=fill!(modm,0.0)` : background seismic model for Born modelling and inversion
* `parameterization::Vector{Symbol}` : subsurface parameterization
  * `=[:χvp, :χρ, :null]` for velocity and density inversion
  * `=[:null, :χρ, :null]` for density-only inversion
  * `=[:χvp, :null, :null]` for velocity-only inversion
* `verbose::Bool=false` : print level on STDOUT during inversion 
* `attrib::Symbol=:synthetic` : an attribute to control class
  * `=:synthetic` synthetic data inversion
  * `=:field` field data inversion
"""
function Param(
	       acqsrc::Acquisition.Src,
	       acqgeom::Acquisition.Geom,
	       tgrid::Grid.M1D,
	       attrib_mod::Union{ModFdtd, ModFdtdBorn, ModFdtdHBorn}, 
	       modm::Models.Seismic;
	       # other optional 
	       tgrid_obs::Grid.M1D=deepcopy(tgrid),
	       recv_fields=[:P],
	       igrid::Grid.M2D=nothing,
	       igrid_interp_scheme::Symbol=:B2,
	       mprecon_factor::Float64=1.0,
	       dobs::Data.TD=Data.TD_zeros(recv_fields,tgrid_obs,acqgeom),
	       dprecon=nothing,
	       tlagssf_fracs=0.0,
	       tlagrf_fracs=0.0,
	       acqsrc_obs::Acquisition.Src=deepcopy(acqsrc),
	       modm_obs::Models.Seismic=modm,
	       modm0::Models.Seismic=fill!(deepcopy(modm),0.0),
	       parameterization::Vector{Symbol}=[:χvp, :χρ, :null],
	       verbose::Bool=false,
	       attrib::Symbol=:synthetic,
	       )

	# make a copy of initial model
	modm=deepcopy(modm)

	if(igrid===nothing)
		igrid=deepcopy(modm.mgrid)
	end
	# igrid has to truncated because the gradient evaluation 
	# is inaccurate on boundaries
	mg=modm.mgrid
	igrid=Grid.M2D(max(mg.x[3],igrid.x[1]),
		min(igrid.x[end],mg.x[end-2]),
		max(igrid.z[1],mg.z[3]),
		min(igrid.z[end],mg.z[end-2]),
		 		igrid.δx,igrid.δz,igrid.npml)


	# create modi according to igrid and interpolation of modm
	modi = Models.Seismic_zeros(igrid);
	# update bounds
	Models.adjust_bounds!(modi, modm)
	Models.interp_spray!(modm, modi, :interp)

	# save the initial model, as modi will be changed during the iterations
	mod_initial=deepcopy(modi)

	# allocate prior inputs
	priori=similar(modi)
	priorw=similar(modi)

	# need a separate model for synthetic
	if(attrib == :synthetic) 
		((attrib_mod == :fdtd_hborn) | (attrib_mod == :fdtd_born)) && 
		isequal(modm0, modm_obs) && error("change background model used for Born modelling")
		isequal(modm, modm_obs) && error("initial model same as actual model")
	end

	# acqgeom geometry for adjoint propagation
	adjacqgeom = AdjGeom(acqgeom)

	# generate adjoint sources
	adjsrc=generate_adjsrc(recv_fields, tgrid, adjacqgeom)

	if(typeof(attrib_mod) == ModFdtd)
		born_flag=false
	else
		born_flag=true
	end

	# generating forward and adjoint modelling engines
	# to generate modelled data, border values, etc.
	# most of the parameters given to this are dummy, except for born_flag
	paf=Fdtd.Param(npw=2, model=modm, born_flag=born_flag,
		acqgeom=[acqgeom, adjacqgeom], acqsrc=[acqsrc, adjsrc], 
		sflags=[3, 2], rflags=[1, 1],
		backprop_flag=1, 
		tgridmod=tgrid, gmodel_flag=true, verbose=verbose, illum_flag=false)


	gmodm=similar(modm)
	gmodi=similar(modi)

	# check dprecon
	if(!(dprecon===nothing))
		(!(isapprox(dprecon,dobs))) && error("invalid dprecon used")
	end
	
	# create Parameters for data misfit
	#coup=Coupling.TD_delta(dobs.tgrid, tlagssf_fracs, tlagrf_fracs, recv_fields, acqgeom)
	# choose the data misfit
	#	(iszero(tlagssf_fracs)) 
 	# tlagssf_fracs==[0.0] | tlagssf_fracs=[0.0])
	# paTD=Data.P_misfit(Data.TD_zeros(recv_fields,tgrid,acqgeom),dobs,w=dprecon,coup=coup, func_attrib=optims[1]);

	if(iszero(dobs))
		randn!(dobs) # dummy dobs, update later
	end

	paTD=Data.P_misfit(Data.TD_zeros(recv_fields,tgrid,acqgeom),dobs,w=dprecon);

	paminterp=Interpolation.Kernel([modi.mgrid.x, modi.mgrid.z], [modm.mgrid.x, modm.mgrid.z], igrid_interp_scheme)

	mx=Inversion.X(modi.mgrid.nz*modi.mgrid.nx*count(parameterization.≠:null),2)
	mxm=Inversion.X(modm.mgrid.nz*modm.mgrid.nx*count(parameterization.≠:null),2)


	# put modm as a vector, according to parameterization in mxm.x
	Models.Seismic_get!(mxm.x,modm,parameterization)

	pa = Param(
	     mx, mxm,
	     paf,
	     deepcopy(acqsrc), 
	     Acquisition.Src_zeros(adjacqgeom, recv_fields, tgrid),
	     deepcopy(acqgeom), 
	     adjacqgeom,
	     attrib_mod,  
	     deepcopy(modm), deepcopy(modm0), modi, mod_initial,
	     priori, priorw,
	     gmodm,gmodi,
	     parameterization,
	     zeros(2,2), # dummy, update mprecon later
	     paTD,
	     paminterp,
	     verbose, attrib)

	# generate observed data if attrib is synthetic
	if((attrib == :synthetic))
		# update model in the same forward engine
		# save modm
		modm_copy=deepcopy(pa.modm)

		# change model to actual model
		copy!(pa.modm, modm_obs)

		F!(pa, nothing, pa.attrib_mod)

		copy!(pa.paTD.y, pa.paTD.x)

		# put back model and sources
		copy!(pa.modm, modm_copy)

	        Fdtd.initialize!(paf.c)  # clear everything
	end
	iszero(dobs) && ((attrib == :real) ? error("input observed data for real data inversion") : error("problem generating synthetic observed data"))

	# generate modelled data
	F!(pa, nothing, pa.attrib_mod)

#	build_mprecon!(pa, Array(pa.paf.c.illum_stack), mprecon_factor)
	pa.paf.c.illum_flag=false # switch off illum flag for speed

	# default weights are 1.0
	pa.mx.w[:]=1.0

	# update priori and priorw in pa to defaults
	update_prior!(pa)
	
	return pa
end


"""
Return the number of inversion variables for FWI corresponding to `Param`.
This number of inversion variables depend on the size of inversion mesh.
"""
function xfwi_ninv(pa::Param)
	length(pa.mx.x)
end

"""
Return the number of inversion variables for source and receiver filter inversion 
corresponding to `Param`.
This number depends on the maximum lagtimes of the filters. 
"""
function wfwi_ninv(pa::Param)
	return  pa.paTD.coup.tgridssf.nx
end

"""
Update inversion variable with the initial model.
At the same time, update the lower and upper bounds on the inversion variable.
"""
function initialize!(pa::Param)

	randn!(pa.mx.last_x)  # reset last_x

	# use mod_initial as starting model according to parameterization
	Models.Seismic_get!(pa.mx.x, pa.mod_initial, pa.parameterization)

	# bounds
	Seismic_xbound!(pa.mx.lower_x, pa.mx.upper_x, pa)

end

# finalize xfwi or wfwi on pa
function finalize!(pa::Param, xminimizer)
	# update modm
	x_to_modm!(pa, xminimizer)

	# update calculated data using the minimizer
	F!(pa, nothing, pa.attrib_mod)

	# put minimizer into modi
	Models.Seismic_reparameterize!(pa.modi, xminimizer, pa.parameterization) 

	# update initial model using minimizer, so that running xfwi! next time will start with updated model
	copy!(pa.mod_initial, pa.modi)
end

"""
Full Waveform Inversion using `Optim` package.
This method updates `pa.modm` and `pa.dcal`. More details about the
optional parameters can be found in the documentation of the `Optim` 
package.
The gradiet is computed using the adjoint state method.
`pa.modi` is used as initial model if non-zero.

# Arguments

* `pa::Param` : inversion object (updated inside method)
* `obj::Union{LS,LS_prior}` : which objective function?
  * `=LS()`
  * `=LS_prior([1.0, 0.5])`

# Optional Arguments

* `optim_options` : see Optim.jl package for optimization options
* `optim_scheme=LBFGS()` : see Optim.jl for other options
* `bounded_flag=true` : use box constraints, see Optim.jl

# Outputs

* updated `modm` in the input `Param`
* returns the result of optimization as an Optim.jl object
  * `=:migr_finite_difference` same as above but *not* using adjoint state method; time consuming; only for testing, TODO: implement autodiff here
"""
function xfwi!(pa::Param, obj::Union{LS,LS_prior}; 
	   optim_scheme=LBFGS(),
	   optim_options=Optim.Options(show_trace=true,
	   store_trace=true, 
	   extended_trace=false, 
	   iterations=5,
	   f_tol=1e-5, 
	   g_tol=1e-8, 
	   x_tol=1e-5, ),
	       bounded_flag=false, solver=nothing, ipopt_options=nothing)

	global to
	reset_timer!(to)

	println("updating modm and modi...")
	println("> xfwi: number of inversion variables:\t", xfwi_ninv(pa)) 

	initialize!(pa)

	f(x) = ζfunc(x, pa.mx.last_x,  pa, obj)
	g!(storage, x) = ζgrad!(storage, x, pa.mx.last_x, pa, obj)
	if(!bounded_flag)
		"""
		Unbounded LBFGS inversion, only for testing
		"""
		@timeit to "xfwi!" begin
			res = optimize(f, g!, pa.mx.x, optim_scheme, optim_options)
		end
	else
		"""
		Bounded LBFGS inversion
		"""
		if (solver == :ipopt)
			function eval_f(x)
			    return ζfunc(x, pa.mx.last_x,  pa, obj)
			end


			function eval_grad_f(x, grad_f)
			    ζgrad!(grad_f, x, pa.mx.last_x, pa, obj)
			end


			function void_g(x, g)
			    
			end

			function void_g_jac(x, mode, rows, cols, values)
			    
			end

			prob = createProblem(size(pa.mx.x)[1], pa.mx.lower_x, pa.mx.upper_x, 0, Array{Float64}(0), Array{Float64}(0), 0, 0,
					eval_f, void_g, eval_grad_f, void_g_jac, nothing)

			addOption(prob, "hessian_approximation", "limited-memory")

			if !(ipopt_options === nothing)
			    for i in 1:size(ipopt_options)[1]
				addOption(prob, ipopt_options[i][1], ipopt_options[i][2])
			    end
			end

			prob.x = pa.mx.x
			    
			@timeit to "xfwi!" begin
				res = solveProblem(prob)
			end
		else
			@timeit to "xfwi!" begin
				res = optimize(f, g!, pa.mx.lower_x, pa.mx.upper_x,pa.mx.x, Fminbox(optim_scheme), optim_options)
			end
                end
	end
	show(to)

	# print some stuff after optimization...
	if (solver == :ipopt)
		pa.verbose && println(ApplicationReturnStatus[res])
	else
		pa.verbose && println(res)
	end
	

	# finalize optimization, using the optimizer... 
	if solver == :ipopt
		finalize!(pa, prob.x)
	else
		finalize!(pa, Optim.minimizer(res))
	end


	return res
end

		#=
		Harvest the Optim result to plot functional and gradient --- to be updated later
		if(extended_trace)
			# convert gradient vector to model
			gmodi = [Models.Seismic_zeros(pa.modi.mgrid) for itr=1:Optim.iterations(res)]
			gmodm = [Models.Seismic_zeros(pa.modm.mgrid) for itr=1:Optim.iterations(res)] 
			modi = [Models.Seismic_zeros(pa.modi.mgrid) for itr=1:Optim.iterations(res)]
			modm = [Models.Seismic_zeros(pa.modm.mgrid) for itr=1:Optim.iterations(res)]
			for itr=1:Optim.iterations(res)
				# update modm and modi
				Seismic_x!(modm[itr], modi[itr], Optim.x_trace(res)[itr], pa, -1)

				# update gmodm and gmodi
				Seismic_gx!(gmodm[itr],modm[itr],gmodi[itr],modi[itr],Optim.trace(res)[itr].metadata["g(x)"],pa,-1)
			end
			
		else
			f = Optim.minimum(res)
		end
		=#


"""
Return gradient at the first iteration, i.e., a migration image
"""
function xfwi!(pa::Param, obj::Migr)

	global to
	reset_timer!(to)

	initialize!(pa)

	g1=pa.mx.gm[1]
	@timeit to "xfwi!" begin
		grad!(g1, pa.mx.x, pa.mx.last_x,  pa)
	end
	show(to)

	# convert gradient vector to model
	visualize_gx!(pa.gmodm, pa.modm, pa.gmodi, pa.modi, g1, pa)

	return pa.gmodi
end


"""
Return gradient at the first iteration, i.e., a migration image, without using
adjoint state method.
"""
function xfwi!(pa::Param, obj::Migr_fd)
	global to
	reset_timer!(to)

	initialize!(pa)
	gx=pa.mx.gm[1]

	println("> number of functional evaluations:\t", xfwi_ninv(pa)) 

	f(x) = ζfunc(x, pa.mx.last_x,  pa, LS())

	gx = Calculus.gradient(f,pa.mx.x) # allocating new gradient vector here
	
	show(to)

	# convert gradient vector to model
	visualize_gx!(pa.gmodm, pa.modm, pa.gmodi, pa.modi, gx, pa)

	return pa.gmodi
end



function xwfwi!(pa; max_roundtrips=100, max_reroundtrips=10, ParamAM_func=nothing, roundtrip_tol=1e-6,
		     optim_tols=[1e-6, 1e-6])

	if(ParamAM_func===nothing)
		ParamAM_func=x->Inversion.ParamAM(x, optim_tols=optim_tols,name="FWI with Source Wavelet Estimation",
				    roundtrip_tol=roundtrip_tol, max_roundtrips=max_roundtrips,
				    max_reroundtrips=max_reroundtrips,
				    min_roundtrips=10,
				    reinit_func=x->initialize!(pa),
				    after_reroundtrip_func=x->(err!(pa); update_calsave!(pa);),
				    )
	end

	
	# create alternating minimization parameters
	f1=x->FWI.wfwi!(pa, extended_trace=false)
	f2=x->FWI.xfwi!(pa, extended_trace=false)
	paam=ParamAM_func([f1, f2])

	# do inversion
	Inversion.go(paam)

	# print errors
	err!(pa)
	println(" ")
end


"build a model precon"
function build_mprecon!(pa,illum::Array{Float64}, mprecon_factor=1.0)
	"illum cannot be zero when building mprecon"
	(any(illum .<= 0.0)) && error("illum cannot be negative or zero")
	(mprecon_factor < 1.0)  && error("invalid mprecon_factor")

	illumi = zeros(pa.modi.mgrid.nz, pa.modi.mgrid.nx)
	Interpolation.interp_spray!(illumi, illum, pa.paminterp, :spray)
	(any(illumi .<= 0.0)) && error("illumi cannot be negative or zero")

	# use log to fix scaling of illum 
	# (note that illum is not the exact diagonal of the Hessian matrix, so I am doing tricks here) 
	# larger the mprecon_factor, stronger the preconditioning
	# division by maximum is safe because illum is non zero
	minillumi = minimum(illumi)
	maxillumi = maximum(illumi)
	illumi -= minillumi; # remove mean 	
	(maxillumi ≠ 0.0) && (illumi ./= maxillumi) # normalize using maxillumi
	#illumi = 1.0 + log.(1. + (mprecon_factor-1) * illumi) # illumi now lies between 1.0 and some value depending on how large illumi is
	illumi = (1. + (mprecon_factor-1) * illumi) # illumi now lies between 1.0 and some value depending on how large illumi is

	illumi = vcat([vec(illumi) for i in 1:count(pa.parameterization.≠:null)]...)

	length(illumi) == xfwi_ninv(pa) ? nothing : error("something went wrong with creating mprecon")
	pa.mprecon = spdiagm(illumi,(0),xfwi_ninv(pa), xfwi_ninv(pa))
end


"""
Return functional and gradient of the LS objective 
* `last_x::Vector{Float64}` : buffer is only updated when x!=last_x, and modified such that last_x=x
"""
function func(x::Vector{Float64}, last_x::Vector{Float64}, pa::Param)
	global to

	if(!isequal(x, last_x))
		copy!(last_x, x)
		# do forward modelling, apply F x
		@timeit to "F!" F!(pa, x, pa.attrib_mod)
	end

	# compute misfit 
	f = Data.func_grad!(pa.paTD)
	return f
end

function grad!(storage, x::Vector{Float64}, last_x::Vector{Float64}, pa::Param)
	global to

	# (inactive when applied on same model)
	if(!isequal(x, last_x))
		copy!(last_x, x)
		# do forward modelling, apply F x 
		@timeit to "F!" F!(pa, x, pa.attrib_mod)
	end

	# compute functional and get ∇_d J (adjoint sources)
	f = Data.func_grad!(pa.paTD, :dJx);

	# update adjoint sources after time reversal
	update_adjsrc!(pa.adjsrc, pa.paTD.dJx, pa.adjacqgeom)

	# do adjoint modelling here with adjoint sources Fᵀ F P x
	@timeit to "Fadj!" Fadj!(pa)	

	# adjoint of interpolation
        spray_gradient!(storage,  pa, pa.attrib_mod)

	return storage
end 



function ζfunc(x, last_x, pa::Param, ::LS)
	return func(x, last_x, pa)
end


function ζgrad!(storage, x, last_x, pa::Param, ::LS)
	return grad!(storage, x, last_x, pa)
end


function ζfunc(x, last_x, pa::Param, obj::LS_prior)
	f1=func(x, last_x, pa)

	f2=Misfits.error_squared_euclidean!(nothing, x, pa.mx.prior, pa.mx.w, norm_flag=false)

	return f1*obj.α[1]+f2*obj.α[2]
end

function ζgrad!(storage, x, last_x, pa::Param, obj::LS_prior)
	g1=pa.mx.gm[1]
	grad!(g1, x, last_x, pa)

	g2=pa.mx.gm[2]
	Misfits.error_squared_euclidean!(g2, x, pa.mx.prior, pa.mx.w, norm_flag=false)

	scale!(g1, obj.α[1])
	scale!(g2, obj.α[2])
	for i in eachindex(storage)
		@inbounds storage[i]=g1[i]+g2[i]
	end
	return storage
end


"""
Update pa.w
"""
function wfwi!(pa::Param; store_trace::Bool=true, extended_trace::Bool=false, time_limit=Float64=2.0*60., 
	       f_tol::Float64=1e-8, g_tol::Float64=1e-8, x_tol::Float64=1e-8)

	# convert initial model to the inversion variable
	x = zeros(wfwi_ninv(pa));
	last_x = rand(size(x)) # reset last_x

	println("updating w...")
	println("> wfwi: number of inversion variables:\t", length(x)) 

	# initial w to x
	Coupling_x!(x, pa, 1)

	(iszero(pa.paTD.y)) && error("dcal zero wfwi")

	f=x->func_grad_Coupling!(nothing, x,  pa)
	g! =(storage,x)->func_grad_Coupling!(storage, x,  pa)

	"""
	Unbounded LBFGS inversion, only for testing
	"""
	res = optimize(f, g!, x, 
		       LBFGS(),
		       Optim.Options(g_tol = g_tol, f_tol=f_tol, x_tol=x_tol,
		       iterations = 1000, store_trace = store_trace,
		       extended_trace=extended_trace, show_trace = true))
	"testing gradient using auto-differentiation"
#	res = optimize(f, x, 
#		       LBFGS(),
#		       Optim.Options(g_tol = 1e-12,
#	 	       iterations = 10, store_trace = true,
#		       extended_trace=true, show_trace = true))

	pa.verbose ? println(res) : nothing
	# update w in pa

	Coupling_x!(Optim.minimizer(res), pa, -1)

	f = Optim.minimum(res)
	return f
end # wfwi


# convert x to modm by interpolation
# x is on the sparse grid, and is changed by parameterization
function x_to_modm!(pa, x)

	# put sparse x into modi (useless step, just for visualization)
	Models.Seismic_reparameterize!(pa.modi, x, pa.parameterization) 

	# get x on dense grid
	Interpolation.interp_spray!(x, pa.mxm.x, pa.paminterp, :interp, count(pa.parameterization.≠:null))

	# put dense x into modm, according to parameterization
	Models.Seismic_reparameterize!(pa.modm,pa.mxm.x,pa.parameterization) 
end

"""
convert the gradient output from Fdtd to gx
"""
function spray_gradient!(gx,  pa, ::ModFdtd)

	# apply chain rule on gmodm to get gradient w.r.t. dense x
	Models.gradient_chainrule!(pa.mxm.gx, pa.paf.c.gradient, pa.modm, pa.parameterization)

	# spray gradient w.r.t. dense x to the space of sparse x
	Interpolation.interp_spray!(gx, pa.mxm.gx, pa.paminterp, :spray, count(pa.parameterization.≠:null))

	# visualize gmodi here?
	# visualize_gx!(pa.gmodm, pa.modm, pa.gmodi, pa.modi, gx, pa)
end
function spray_gradient!(gx, pa, ::ModFdtdBorn)

	# apply chain rule on gmodm to get gradient w.r.t. dense x (note that background model is used for Born modeling here)
	Models.gradient_chainrule!(pa.mxm.gx, pa.paf.c.gradient, pa.modm0, pa.parameterization)

	# spray gradient w.r.t. dense x to the space of sparse x
	Interpolation.interp_spray!(gx, pa.mxm.gx, pa.paminterp, :spray, count(pa.parameterization.≠:null))

	# visualize gmodi here?
	# visualize_gx!(pa.gmodm, pa.modm, pa.gmodi, pa.modi, gx, pa)
end



"""
Return bound vectors for the `Seismic` model, 
depeding on paramaterization
"""
function Seismic_xbound!(lower_x, upper_x, pa)
	nznx = pa.modi.mgrid.nz*pa.modi.mgrid.nx;

	bound1 = similar(lower_x)
	# create a Seismic model with minimum possible values
	modbound = deepcopy(pa.modi);
	modbound.χvp = Models.χ(fill(modbound.vp0[1], size(modbound.χvp)), modbound.ref.vp)
	modbound.χvs = Models.χ(fill(modbound.vs0[1], size(modbound.χvs)), modbound.ref.vs)
	modbound.χρ = Models.χ(fill(modbound.ρ0[1], size(modbound.χρ)), modbound.ref.ρ)

	Models.Seismic_get!(bound1,modbound,pa.parameterization)


	bound2=similar(upper_x)
	# create a Seismic model with maximum possible values
	modbound.χvp = Models.χ(fill(modbound.vp0[2], size(modbound.χvp)), modbound.ref.vp)
	modbound.χvs = Models.χ(fill(modbound.vs0[2], size(modbound.χvs)), modbound.ref.vs)
	modbound.χρ = Models.χ(fill(modbound.ρ0[2], size(modbound.χρ)), modbound.ref.ρ)

	Models.Seismic_get!(bound2,modbound,pa.parameterization)

	# this sorting operation is important because 
	lower_x[:] = min.(bound1, bound2)
	upper_x[:] = max.(bound1, bound2)

	return modbound
end

# gmodi, gmodm <-- gx (just for visualizing gradient)
function visualize_gx!(gmodm, modm, gmodi, modi, gx, pa)
	# chain rule depending on re-parameterization
	Models.Seismic_chainrule!(gmodi, modi, gx, pa.parameterization, 1)

	# get gradient after interpolation (just for visualization, not exact)
	Models.interp_spray!(gmodi, gmodm, :interp, pa=pa.paminterp)
end

"""
Modify the input acquisition geometry 
such that the adjoint source time functions can 
be propagated from the receiver positions.
The number of supersources will remain the same.
All the recievers will be fired as simultaneous sources.
"""
function AdjGeom(geomin::Acquisition.Geom)
	geomout = deepcopy(geomin);
	geomout.sx = geomin.rx; geomout.sz = geomin.rz;
	geomout.ns = geomin.nr; 

#	geomout.rx = geomin.sx; geomout.rz = geomin.sz;
#	geomout.nr = geomin.ns; 

	geomout.rx = geomin.rx; geomout.rz = geomin.rz;
	geomout.nr = geomin.nr; 

	return geomout
end


"""
Return functional and gradient of the LS objective 
"""
function func_grad_Coupling!(storage, x::Vector{Float64},pa::Param)

	pa.verbose ? println("computing gradient...") : nothing

	# x to w 
	Coupling_x!(x, pa, -1)

	if(storage === nothing)
		# compute misfit 
		f = Data.error!(pa.paTD)
		return f
	else
		f = Data.error!(pa.paTD, :dJssf)
		Coupling_gx!(storage, pa.paTD.dJssf)
		return storage
	end
end

"""
Convert coupling functions to x and vice versa
"""
function Coupling_x!(x::Vector{Float64}, 
		   pa::Param, 
		   flag::Int64)
	if(flag ==1) # convert w to x
		iss=1 # take only first source
		for ifield=1:length(pa.paTD.y.fields)
			w=pa.paTD.coup.ssf[iss,ifield]
			for i in eachindex(x)
				x[i]=w[i] # take only first source
			end
		end
	elseif(flag == -1) # convert x to w
		for iss=1:pa.paTD.y.acqgeom.nss, ifield=1:length(pa.paTD.y.fields)
			w=pa.paTD.coup.ssf[iss,ifield]
			for i in eachindex(x)
				w[i]=x[i]
			end
		end
	else
		error("invalid flag")
	end
end

"""
Convert dJssf to gradient vector
"""
function Coupling_gx!(gx, dJssf)
	gx[:]=0.0
	for ifield=1:size(dJssf,2), iss=1:size(dJssf,1)
		dwav=dJssf[iss,ifield]
		for i in eachindex(gx)
			gx[i]+=dwav[i]
		end
	end
end




end # module