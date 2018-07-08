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

import JuMIT.Models
import JuMIT.Acquisition
import JuMIT.Data
import JuMIT.Coupling
import JuMIT.Fdtd
using Optim, LineSearches
using DistributedArrays


"""
FWI Parameters

# Fields

* `mgrid::Grid.M2D` : modelling grid
* `igrid::Grid.M2D` : inversion grid
* `acqsrc::Acquisition.Src` : base source wavelet for modelling data
* `acqgeom::Acquisition.Geom` : acquisition geometry
* `tgrid::Grid.M1D` : 
* `attrib_mod::Symbol`
* `model_obs` : model used for generating observed data
* `model0` : background velocity model (only used during Born modeling and inversion)
* `parameterization` : a vector of Symbols specifying parameterization of the inversion vector
* `verbose` : print level on STOUT
* `attrib` : synthetic or real

TODO: add an extra attribute for coupling functions inversion and modelling
"""
type Param
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
	attrib_mod::Symbol
	"inversion attribute"
	attrib_inv::Symbol
	"Seismic model on modeling grid"
	modm::Models.Seismic
	"background Seismic model"
	modm0::Models.Seismic
	"Seismic on inversion grid"
	modi::Models.Seismic
	"gradient Seismic model on modeling grid"
	gmodm::Models.Seismic
	"gradient Seismic on inversion grid"
	gmodi::Models.Seismic
	"parameterization"
	parameterization::Vector{Symbol}
	"model preconditioning"
	mprecon::AbstractArray{Float64,2}
	"compute data misfit"
	paTD::Data.P_misfit
	paminterp::Interpolation.Param{Float64}
	optims::Vector{Symbol} # :cls, xcorrcls.. ?
	verbose::Bool
	"synthetic or field inversion"
	attrib::Symbol
	"update buffer in every iteration?"
	buffer_update_flag::Bool
end


"""
Convert the data `TD` to `Src` after time reversal.
"""
function update_adjsrc!(adjsrc, δdat::Data.TD, adjacqgeom)
	for i in 1:adjacqgeom.nss, j in 1:length(δdat.fields)
		adjsrc.wav[i,j] = (flipdim(δdat.d[i,j],1))
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
* `attrib_mod::Symbol` : modelling attribute
* `attrib_inv::Symbol` : inversion attribute
* `modm::Models.Seismic` : seismic model on modelling mesh 

# Optional Arguments
* `tgrid_obs::Grid.M1D` : time grid for observed data

* `igrid::Grid.M2D=modm.mgrid` : inversion grid if different from the modelling grid, i.e., `modm.mgrid`
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
* `mod_inv_parameterization::Vector{Symbol}=[:χKI, :χρI]` : subsurface parameterization
* `verbose::Bool=false` : print level on STDOUT during inversion 
* `attrib::Symbol=:synthetic` : an attribute to control class
  * `=:synthetic` synthetic data inversion
  * `=:field` field data inversion
"""
function Param(
	       acqsrc::Acquisition.Src,
	       acqgeom::Acquisition.Geom,
	       tgrid::Grid.M1D,
	       attrib_mod::Symbol, 
	       attrib_inv::Symbol,
	       modm::Models.Seismic;
	       # other optional 
	       tgrid_obs::Grid.M1D=deepcopy(tgrid),
	       recv_fields=[:P],
	       igrid::Grid.M2D=deepcopy(modm.mgrid),
	       mprecon_factor::Float64=1.0,
	       dobs::Data.TD=Data.TD_zeros(recv_fields,tgrid_obs,acqgeom),
	       dprecon=nothing,
	       tlagssf_fracs=0.0,
	       tlagrf_fracs=0.0,
	       acqsrc_obs::Acquisition.Src=deepcopy(acqsrc),
	       modm_obs::Models.Seismic=modm,
	       modm0::Models.Seismic=fill!(deepcopy(modm),0.0),
	       mod_inv_parameterization::Vector{Symbol}=[:χKI, :χρI],
	       born_flag::Bool=false,
	       verbose::Bool=false,
	       attrib::Symbol=:synthetic,
	       optims=[:cls]
	       )

	# make a copy of initial model
	modm=deepcopy(modm)

	# create modi according to igrid and interpolation of modm
	modi = Models.Seismic_zeros(igrid);
	Models.interp_spray!(modm, modi, :interp)

	#
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

	# generating forward and adjoint modelling engines
	# generate modelled data, border values, etc.
	if(attrib_mod == :fdtd)
		paf=Fdtd.Param(npw=2, model=modm, born_flag=born_flag,
			acqgeom=[acqgeom, adjacqgeom], acqsrc=[acqsrc, adjsrc], sflags=[3, 2],
			backprop_flag=1, 
			tgridmod=tgrid, gmodel_flag=true, verbose=verbose, illum_flag=true)


#		paf=Fdtd.Param(model=modm, acqgeom=[acqgeom], 
#		    acqsrc=[acqsrc],sflags=[2],illum_flag=illum_out, 
#		    backprop_flag=1,tgridmod=tgrid) 
	elseif(attrib_mod == :fdtd_born)
		# Two propagating fields, both in the background model.
		backprop_flag = pa.buffer_update_flag ? 1 : 0

		paf=Fdtd.Param(born_flag=true, npw=2, model=modm0, 
		    model_pert=modm, 
		    acqgeom=[acqgeom, acqgeom], acqsrc=[acqsrc, acqsrc], 
		    illum_flag=illum_out,
		    backprop_flag=backprop_flag,
		    sflags=[2, 0], rflags = [0, 1], 
		    tgridmod=tgrid);

		# switch off buffer update from now on (because the buffer doesn't change with x)
		pa.buffer_update_flag = false
	elseif(attrib_mod == :fdtd_hborn)
		if(pa.buffer_update_flag)
			# storing boundary values 
			paf=Fdtd.mod!(model=pa.modm0, acqgeom=[pa.acqgeom], 
					 acqsrc=[acqsrc], 
					 backprop_flag=1,
					 tgridmod=tgrid, 
					 sflags=[2], rflags=[0], verbose=verbose)
			# switch off buffer update from now on (because the buffer doesn't change with x)
			pa.buffer_update_flag = false
		end

		paf=Fdtd.Param(backprop_flag=-1, 
		    npw=2, model=pa.modm0, model_pert=model, 
		    acqgeom=[acqgeom, acqgeom], 
		    illum_flag=illum_out,
		    acqsrc=[acqsrc, acqsrc], sflags=[3, 0], 
		    rflags=[0, 1],
		    tgridmod=tgrid, born_flag=true, verbose=pa.verbose);

	else
		error("invalid pa.attrib_mod")
	end

#	if(attrib_mod == :fdtd)
#		# adjoint simulation
#		pafa=Fdtd.Param(npw=2, model=modm,
#			acqgeom=[acqgeom, adjacqgeom], acqsrc=[acqsrc, adjsrc], sflags=[3, 2],
#			backprop_flag=-1, 
#			tgridmod=tgrid, gmodel_flag=true, verbose=verbose)
#
#	elseif(attrib_mod == :fdtd_born)
#		# adjoint simulation
#		pafa=Fdtd.Param(npw=2, model=modm0,  
#			acqgeom=[acqgeom, adjacqgeom], acqsrc=[acqsrc, adjsrc], sflags=[3, 2], 
#			backprop_flag=-1, 
#			tgridmod=tgrid, gmodel_flag=true, verbose=verbose)
#
#	elseif(attrib_mod == :fdtd_hborn)
#		# adjoint simulation
#		pafa=Fdtd.Param(npw=2, model=modm0,  
#			acqgeom=[acqgeom, adjacqgeom], acqsrc=[acqsrc, adjsrc], sflags=[2, 2], 
#			tgridmod=tgrid, gmodel_flag=true, verbose=verbose)
#	else
#		error("invalid pa.attrib_mod")
#	end

	gmodm=similar(modm)
	gmodi=similar(modi)

	# check dprecon
	if(!(dprecon===nothing))
		(!(isapprox(dprecon,dobs))) && error("invalid dprecon used")
	end
	# generate observed data if attrib is synthetic
	if((attrib == :synthetic) & iszero(dobs))
		# update model in the same forward engine
		# save modm
		modm_copy=deepcopy(modm)
		Fdtd.update_model!(paf.c, modm_obs)

		paf.c.activepw=[1,]
		paf.c.sflags=[2, 0]
		paf.c.illum_flag=false
		# update sources in the forward engine
		Fdtd.update_acqsrc!(paf, [acqsrc_obs, adjsrc])
		paf.c.backprop_flag=0
		paf.c.gmodel_flag=false

		# F
		Fdtd.mod!(paf);
		dobs1=paf.c.data[1]
		Data.interp_spray!(dobs1, dobs, :interp, :B1)

	        Fdtd.initialize!(paf.c)  # clear everything

		# put back model and sources
		Fdtd.update_model!(paf.c, modm_copy)
		Fdtd.update_acqsrc!(paf, [acqsrc, adjsrc])
	end
	iszero(dobs) && ((attrib == :real) ? error("input observed data for real data inversion") : error("problem generating synthetic observed data"))

	# create Parameters for data misfit
	coup=Coupling.TD_delta(dobs.tgrid, tlagssf_fracs, tlagrf_fracs, recv_fields, acqgeom)
	paTD=Data.P_misfit(Data.TD_zeros(recv_fields,tgrid,acqgeom),dobs,w=dprecon,coup=coup, func_attrib=optims[1]);

	paminterp=Interpolation.Param([modi.mgrid.x, modi.mgrid.z], [modm.mgrid.x, modm.mgrid.z], :B2)
	pa = Param(paf,
	     deepcopy(acqsrc), 
	     Acquisition.Src_zeros(adjacqgeom, recv_fields, tgrid),
	     deepcopy(acqgeom), 
	     adjacqgeom,
	     attrib_mod, attrib_inv, 
	     deepcopy(modm), deepcopy(modm0), modi, 
	     gmodm,gmodi,
	     deepcopy(mod_inv_parameterization),
	     zeros(2,2), # dummy, update mprecon later
	     paTD,
	     paminterp,
	     optims,
	     verbose, attrib, true)


	# update pdcal
	pa.paf.c.activepw=[1,]
	pa.paf.c.sflags=[2, 0]
	pa.paf.c.illum_flag=true
	Fdtd.update_acqsrc!(pa.paf,[pa.acqsrc, pa.adjsrc])
	pa.paf.c.backprop_flag=0
	pa.paf.c.gmodel_flag=false
	Fdtd.mod!(pa.paf)
	
	build_mprecon!(pa, Array(pa.paf.c.illum_stack), mprecon_factor)
	pa.paf.c.illum_flag=false # switch off illum flag for speed

	dcal=pa.paf.c.data[1]
	copy!(pa.paTD.x, dcal)


	return pa
end


"""
Return the number of inversion variables for FWI corresponding to `Param`.
This number of inversion variables depend on the size of inversion mesh.
"""
function xfwi_ninv(pa::Param)
	return 2*pa.modi.mgrid.nz*pa.modi.mgrid.nx
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
Full Waveform Inversion using `Optim` package.
This method updates `pa.modm` and `pa.dcal`. More details about the
optional parameters can be found in the documentation of the `Optim` 
package.
`pa.modi` is used as initial model if non-zero.

# Arguments that are modified

* `pa::Param` : inversion parameters

# Optional Arguments

* `extended_trace::Bool=true` : save extended trace
* `time_limit=Float64=2.0*60.` : time limit for inversion (testing)
* `iterations::Int64=5` : maximum number of iterations
* `linesearch_iterations::Int64=3` : maximum number of line search iterations

* `f_tol::Float64=1e-5` : functional tolerance
* `g_tol::Float64=1e-8` : gradient tolerance
* `x_tol::Float64=1e-5` : model tolerance

# Outputs

* depending on  `pa.attrib_inv`
  * `=:cls` classic least-squares inversion using adjoint state method
  * `=:migr` return gradient at the first iteration, i.e., a migration image
  * `=:migr_finite_difference` same as above but *not* using adjoint state method; time consuming; only for testing, TODO: implement autodiff here
"""
function xfwi!(pa::Param; store_trace::Bool=true, extended_trace::Bool=false, time_limit=Float64=2.0*60., iterations::Int64=5,
	       f_tol::Float64=1e-5, g_tol::Float64=1e-8, x_tol::Float64=1e-5, linesearch_iterations::Int64=3, bounded_flag=false)

	# convert initial model to the inversion variable
	x = zeros(xfwi_ninv(pa));
	last_x = similar(x)
	println("updating modm and modi...")
	println("> xfwi: number of inversion variables:\t", length(x)) 

	last_x = rand(size(x)) # reset last_x

	# replace x and modi with initial model (pa.modm)
	if(iszero(pa.modi)) # then use modm
		iszero(pa.modm) ? error("no initial model present in pa") :	Seismic_x!(pa.modm, pa.modi, x, pa, 1)
	else
		# use modi as starting model without disturbing modm
		Seismic_x!(nothing, pa.modi, x, pa, 1)
	end

	# bounds
	lower_x = similar(x); upper_x = similar(x);
	Seismic_xbound!(lower_x, upper_x, pa)

	const to = TimerOutput(); # create a timer object
	if(pa.attrib_inv == :cls)
		f(x) = @timeit to "f" func_grad_xfwi!(nothing, x, last_x,  pa)
		g!(storage, x) = @timeit to "g!" func_grad_xfwi!(storage, x, last_x, pa)
		begin
			reset_timer!(to)
			if(!bounded_flag)
				"""
				Unbounded LBFGS inversion, only for testing
				"""
				@timeit to "xfwi!" begin
					res = optimize(f, g!, x, 
				         LBFGS(),
				         Optim.Options(g_tol = g_tol,
				         iterations = iterations, store_trace = store_trace,
				         extended_trace=extended_trace, show_trace = true))
				end
				show(to)
			else

				"""
				Bounded LBFGS inversion
				"""
				@timeit to "xfwi!" begin
					res = optimize(f, g!, lower_x, upper_x, 
					 x,  
			       Fminbox(LBFGS()), # actual iterations
			       # LBFGS was behaving wierd with backtracking
	       # to reduce the number of gradient calls
	       #linesearch = BackTracking(order=3), 
	       #linesearch = Optim.LineSearches.morethuente!,
			     Optim.Options(
				  g_tol = g_tol, f_tol=f_tol, x_tol=x_tol,
	       # iterations inside every line search, I choose 3 because better performance on Rosenbrock
	#	 			outer_iterations = linesearch_iterations, 
					#time_limit=time_limit,
					store_trace=store_trace,extended_trace=extended_trace, show_trace=true))
				end
				show(to)
			end
		end
		pa.verbose && println(res)

		# update modm and modi
		Seismic_x!(pa.modm, pa.modi, Optim.minimizer(res), pa, -1)

		# update calculated data in pa
		pa.paf.c.activepw=[1,]
		pa.paf.c.sflags=[2, 0]
		pa.paf.c.illum_flag=false
		Fdtd.update_acqsrc!(pa.paf,[pa.acqsrc, pa.adjsrc])
		pa.paf.c.backprop_flag=0
		pa.paf.c.gmodel_flag=false
		Fdtd.mod!(pa.paf)

		dcal=pa.paf.c.data[1]
		copy!(pa.paTD.x, dcal)


		# leave buffer update flag to true before leaving xfwi
		pa.buffer_update_flag = true

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
		return res
	elseif(pa.attrib_inv == :migr)
		storage = similar(x)
		func_grad_xfwi!(storage, x, last_x,  pa)

		# convert gradient vector to model
		Seismic_gx!(pa.gmodm,pa.modm,pa.gmodi,pa.modi,storage, pa,-1)
		println("maximum value of g(x):\t",  maximum(storage))

		# leave buffer update flag to true before leaving xfwi
		pa.buffer_update_flag = true

		return pa.gmodi
	elseif(pa.attrib_inv == :migr_finite_difference)

		gx = similar(x);
		gx = Inversion.finite_difference!(x -> func_grad_xfwi!(nothing, x, last_x,  pa), x, gx, :central)

		# convert gradient vector to model
		Seismic_gx!(pa.gmodm,pa.modm,pa.gmodi,pa.modi,gx,pa,-1)
		println("maximum value of g(x):\t",  maximum(gx))

		# leave buffer update flag to true before leaving xfwi
		pa.buffer_update_flag = true
		return pa.gmodi
	else
		error("invalid pa.attrib_inv")
	end
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


"""
Perform a forward simulation.
This simulation is common for both functional and gradient calculation.
During the computation of the gradient, we need an adjoint simulation.
Update the buffer, which consists of the modelled data
and boundary values for adjoint calculation.

# Arguments

* `x::Vector{Float64}` : inversion variable
* `last_x::Vector{Float64}` : buffer is only updated when x!=last_x, and modified such that last_x=x
* `pa::Param` : parameters that are constant during the inversion 
* `modm::Models.Seismic` : 
"""
function F!(pa::Param, x, last_x=[0.0])
	if(x!=last_x)
		pa.verbose && println("updating buffer")
		(size(last_x)==size(x)) && (last_x[:] = x[:])

		if(!(x===nothing))
			Seismic_x!(pa.modm, pa.modi, x, pa, -1)		
			# update model in the forward engine
			Fdtd.update_model!(pa.paf.c, pa.modm)
		end

		pa.paf.c.activepw=[1,]
		pa.paf.c.illum_flag=false
		pa.paf.c.sflags=[2, 0]
		Fdtd.update_acqsrc!(pa.paf,[pa.acqsrc,pa.adjsrc])
		pa.paf.c.backprop_flag=1
		pa.paf.c.gmodel_flag=false

		Fdtd.mod!(pa.paf);
		dcal=pa.paf.c.data[1]
		copy!(pa.paTD.x,dcal)
	end
end

"""
Born modeling with `modm` as the perturbed model and `modm0` as the background model.
"""
function Fborn!(pa::Param)
	# update background and perturbed models in the forward engine
	Fdtd.update_model!(pa.paf.c, pa.modm0, pa.modm)

	pa.paf.c.activepw=[1,2] # two wavefields are active
	pa.paf.c.illum_flag=false 
	pa.paf.c.sflags=[2, 0] # no sources on second wavefield
	pa.paf.c.rflags=[0, 1] # record only after first scattering

	# source wavelets (for second wavefield, they are dummy)
	Fdtd.update_acqsrc!(pa.paf,[pa.acqsrc,pa.adjsrc])

	pa.paf.c.backprop_flag=1 # store boundary values for gradient later
	pa.paf.c.gmodel_flag=false # no gradient
	
	# switch on born scattering
	pa.paf.c.born_flag=true

	Fdtd.mod!(pa.paf);
	dcal=pa.paf.c.data[2]
	copy!(pa.paTD.x,dcal)

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

	illumi = vcat(vec(illumi), vec(illumi))

	length(illumi) == xfwi_ninv(pa) ? nothing : error("something went wrong with creating mprecon")
	pa.mprecon = spdiagm(illumi,(0),xfwi_ninv(pa), xfwi_ninv(pa))
end


"""
Return functional and gradient of the CLS objective 
"""
function func_grad_xfwi!(storage, x::Vector{Float64}, last_x::Vector{Float64}, pa::Param)

	pa.verbose && println("computing gradient...")

	# do forward modelling, apply F x
	F!(pa, x, last_x)

	if(storage === nothing)
		# compute misfit 
		f = Data.func_grad!(pa.paTD)
		return f
	else
		# compute functional and get ∇_d J (adjoint sources)
		f = Data.func_grad!(pa.paTD, :dJx)

		# update adjoint sources after time reversal
		update_adjsrc!(pa.adjsrc, pa.paTD.dJx, pa.adjacqgeom)

		# project x, which lives in modi, on to model space (modm)
		Seismic_x!(pa.modm, pa.modi, x, pa, -1)		

		# put modm into Fdtd
		Fdtd.update_model!(pa.paf.c, pa.modm)

		# do adjoint modelling here with adjoint sources Fᵀ F P x
		Fadj!(pa)	
	
		# adjoint of interpolation
		Seismic_gx!(pa.gmodm,pa.modm,pa.gmodi,pa.modi,storage,pa,1) 

		return storage
	end
end # func_grad_xfwi!


"""
Perform adjoint modelling in `paf` using adjoint sources `adjsrc`.
"""
function Fadj!(pa::Param)

	# both wavefields are active
	pa.paf.c.activepw=[1,2]

	# no need of illum during adjoint modeling
	pa.paf.c.illum_flag=false

	# force boundaries in first pw and back propagation for second pw
	pa.paf.c.sflags=[3,2] 
	pa.paf.c.backprop_flag=-1

	# update source wavelets in paf using adjoint sources
	Fdtd.update_acqsrc!(pa.paf,[pa.acqsrc,pa.adjsrc])

	# require gradient
	pa.paf.c.gmodel_flag=true

	# adjoint modelling
	Fdtd.mod!(pa.paf);

	# copy gradient
	copy!(pa.gmodm,pa.paf.c.gmodel)
end


"""
Return the inversion variable of `xfwi` with mostly zeros and 
non-zero at only one element corresponding to a location `loc`.

Note: this method will modify `modm` and `modi`.
"""
function xfwi_pert_x(pa,loc)
	# allocate
	x = zeros(xfwi_ninv(pa))
	return xfwi_pert_x!(x,pa,loc)
end
"""
"""
function xfwi_pert_x!(x, pa, loc)

	fill!(pa.modm, 0.0)
	fill!(pa.modi, 0.0)

	# add a point perturbation
	Models.Seismic_addon!(pa.modi, point_loc=loc, point_pert=0.1) 

	# update x
	Seismic_x!(nothing, pa.modi, x, pa, 1)		

	return x
end


"""
xx = Fadj * Fborn * x
"""
function Fadj_Fborn_x!(xx, x, pa)

	# put  x into pa
	Seismic_x!(pa.modm, pa.modi, x, pa, -1)		

	# generate Born Data
	(pa.paf.c.born_flag==false) && error("need born flag")
	Fborn!(pa)

	#f = Data.func_grad!(pa.paTD, :dJx)

	# adjoint sources
	update_adjsrc!(pa.adjsrc, pa.paTD.x, pa.adjacqgeom)

	# adjoint simulation
	Fadj!(pa)

	# adjoint of interpolation
	Seismic_gx!(pa.gmodm, pa.modm, pa.gmodi, pa.modi, xx, pa, 1) 

	return pa
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

"""
Convert `Seismic` model to x and vice versa

* `modm` : seismic model on modelling grid (input nothing to not use it)
* `modi::Models.Seismic` : seismic model on inversion grid
* `x::Vector{Float64}` : inversion vector
* `pa::Param` : fwi parameters
* `flag::Int64` : 
  * `=1` converts either modm or modi to x
  * `=-1` updates both modm and modi using x
"""
function Seismic_x!(
		    modm, 
		    modi::Models.Seismic,
		    x::Vector{Float64}, 
		    pa::Param, 
		    flag::Int64)
	if(flag ==1) # convert modm or modi to x
		if(modm===nothing)
			all([iszero(modi)]) && error("input modi") 
		else
			all([iszero(modm), iszero(modi)]) && error("input modi or modm")

			# 1. get modi using interpolation and modm (use pa interp later, not used during inversion a lot)
			!(iszero(modm)) && Models.interp_spray!(modm, modi, :interp)
		end

		nznx = pa.modi.mgrid.nz*pa.modi.mgrid.nx;
		# 2. re-parameterization on the inversion grid (include other parameterizations here)
		x[1:nznx] = copy(vec(Models.Seismic_get(modi,pa.parameterization[1])));
		x[nznx+1:2*nznx] = copy(vec(Models.Seismic_get(modi,pa.parameterization[2])));

		# apply preconditioner
		x[:] =  copy(pa.mprecon * x)

	elseif(flag == -1) # convert x to mod

		nznx = pa.modi.mgrid.nz*pa.modi.mgrid.nx
		modi.mgrid = deepcopy(pa.modi.mgrid); 
		modi.vp0 = pa.modm.vp0; modi.vs0 = pa.modm.vs0; modi.ρ0 = pa.modm.ρ0;

		# apply preconditioner 
		Px = copy(pa.mprecon \ x)

		# 1. re-parameterization on the inversion grid
		Models.Seismic_reparameterize!(modi, reshape(Px[1:nznx],pa.modi.mgrid.nz, pa.modi.mgrid.nx), 
			     reshape(Px[nznx+1:2*nznx],pa.modi.mgrid.nz,pa.modi.mgrid.nx), pa.parameterization)

		# 2. interpolation from the inversion grid to the modelling grid
		modm.mgrid = deepcopy(pa.modm.mgrid); 
		Models.interp_spray!(modi, modm, :interp, pa=pa.paminterp)
	else
		error("invalid flag")
	end
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
	modbound.χvp = Models.χ(fill(modbound.vp0[1], size(modbound.χvp)), modbound.vp0)
	modbound.χvs = Models.χ(fill(modbound.vs0[1], size(modbound.χvs)), modbound.vs0)
	modbound.χρ = Models.χ(fill(modbound.ρ0[1], size(modbound.χρ)), modbound.ρ0)

	Seismic_x!(nothing, modbound, bound1, pa, 1) # update lower_x using such a model


	bound2=similar(upper_x)
	# create a Seismic model with maximum possible values
	modbound.χvp = Models.χ(fill(modbound.vp0[2], size(modbound.χvp)), modbound.vp0)
	modbound.χvs = Models.χ(fill(modbound.vs0[2], size(modbound.χvs)), modbound.vs0)
	modbound.χρ = Models.χ(fill(modbound.ρ0[2], size(modbound.χρ)), modbound.ρ0)

	Seismic_x!(nothing, modbound, bound2, pa, 1) # update upper_x using such a model

	# this sorting operation is important because 
	lower_x[:] = min.(bound1, bound2)
	upper_x[:] = max.(bound1, bound2)

	return modbound
end

"""
Convert gradient vector to `Seismic` type and vice versa
This will be different from the previous one, once 
the parameterizations come in

* `gmodm::Models.Seismic` : gradient model on the modelling grid
* `modm::Models.Seismic` : model on the modelling grid
* `gmodi::Models.Seismic` : gradient model on the inversion grid
* `modi::Models.Seismic` : model on the inversion grid
* `gx::Vector{Float64}` : gradient vector
* `pa::Param` :
* `flag::Int64` :
  * `=1` update the vector `gx` using `gmod`
  * `=-1` update gmod 
"""
function Seismic_gx!(gmodm::Models.Seismic,
		     modm:: Models.Seismic,
		     gmodi::Models.Seismic,
		     modi::Models.Seismic,
	             gx::Vector{Float64},
	             pa::Param,
	             flag::Int64 
		      )
	nznx=modi.mgrid.nz*modi.mgrid.nx
	g1=zeros(nznx); g2 =zeros(nznx)
	isapprox(gmodm, modm) ? nothing : error("gmodm, modm dimensions")
	isapprox(gmodi, modi) ? nothing : error("gmodi, modi dimensions")
	length(gx) == xfwi_ninv(pa) ? nothing : error("gx dimensions")
	if(flag ==1) # convert gmod to gx

		# either gmodi or gmodm should be nonzero
		all([iszero(gmodm), iszero(gmodi)]) ? 
					error("input gmodi or gmodm") : nothing


		# 1. update gmodi by spraying gmodm
		iszero(gmodm) ? nothing : Models.interp_spray!(gmodi, gmodm, :spray, pa=pa.paminterp)

		# 2. chain rule on gmodi 
		Models.Seismic_chainrule!(gmodi, modi, g1, g2, pa.parameterization,-1)

		# 3. copy 
		gx[1:nznx] = copy(g1);
		gx[nznx+1:2*nznx] = copy(g2)

		# modify gradient as mprecon is applied to the model vector 
		gx[:] = copy(pa.mprecon \ gx)

	elseif(flag == -1) # convert gx to mod
		# this flag is only used while visuavalizing the gradient vector,
		# the operations are not exact adjoint of flag==1

		# apply preconditioner, commented as the gx to mod is inexact

		#gx =  copy(pa.mprecon * gx)

		# 1. chain rule depending on re-parameterization
		#    and 
		g1 = gx[1:nznx]; g2 = gx[nznx+1:2*nznx];
		Models.Seismic_chainrule!(gmodi, modi, g1, g2, pa.parameterization, 1)

		# 2. get gradient after interpolation (just for visualization, not exact)
		Models.interp_spray!(gmodi, gmodm, :interp, pa=pa.paminterp)
	else
		error("invalid flag")
	end
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
Return functional and gradient of the CLS objective 
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