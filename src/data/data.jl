




#=

"""
This module defines the data types related to seismic data:
* `TD` : time domain representation

It also provides methods that apply source and receiver filters onto 
seismic data.
"""

using Misfits
using LinearAlgebra
using Statistics
import GeoPhyInv.Interpolation
import GeoPhyInv: AGeom
import GeoPhyInv.Utils
import GeoPhyInv.Coupling
using DSP
using Random

"""
Time domain representation of Seismic Data.

# Fields

* `d::Array{Array{Float64,2},2}` : data 
* `fields::Vector{Symbol}` : components recorded at each receiver
* `tgrid` : grid to represent time
* `ageom::AGeom` : acquisition ageometry used to generate the data
"""
mutable struct TD
	tgrid::StepRangeLen{Float64,Base.TwicePrecision{Float64},Base.TwicePrecision{Float64}}
	d::NamedArrays.NamedArray{Array{Float64,2},1,Array{Array{Float64,2},1},Tuple{OrderedCollections.OrderedDict{Symbol,Int64}}}
	nr::Int64
	"adding conditions that are to be false while construction"
	#TD(d, fields, tgrid, ageom) = 
#		any([
#		  any([fields[ifield] ∉ [:P, :Vx, :Vz] for ifield in 1:length(fields)]),
#		  length(fields) == 0,
#		  broadcast(size,d) != [(length(tgrid),ageom[iss].nr) for iss=1:length(ageom), ifield=1:length(fields)]
#		  ]) ? 
#		error("error in TD construction") : new(d, fields, tgrid, ageom)
end

"""
Initialize TD with zeros
"""
function Base.zero(::Type{TD}, tgrid, r::Recs=Recs(1), fields=[:P])
	nt=length(tgrid); nf=length(fields)
	return TD(tgrid,NamedArray([zeros(nt,r.n) for i in fields], (fields,)), r.n)
end
TD(tgrid,  r::Recs=Recs(1), fields=[:P])=zero(TD, tgrid, s, fields)



Data=Array{NamedD,1}


"""
Method to resample data in time.

# Arguments

* `data::TD` : input data of type `TD`
* `tgrid` : resampling in time according to this time grid

# Return

* data after resampling as `TD`
"""
function interp(data::TD,
		tgrid::StepRangeLen
		)
	nss = length(data.ageom)
	nr = data.ageom.nr
	dataout = TD(
		     [zeros(length(tgrid),data.ageom[iss].nr) for iss=1:nss, ifield=1:length(data.fields)],
	      data.fields,tgrid,data.ageom)
	interp_spray!(data, dataout)
	return dataout
end

function taper!(data::TD, perc=0.0; bperc=perc,eperc=perc)
	nr = data.ageom.nr;	nss = length(data.ageom); nt = length(data.tgrid);
	for ifield = 1:length(data.fields), iss = 1:nss
		dd=data.d[iss, ifield]
		Utils.taper!(dd,bperc=bperc,eperc=eperc)
	end
	return data
end


"""
Method to resample data in time.
Can reduce allocations =========

# Arguments

* `data::TD` : input data of type `TD`
* `dataout::TD` : preallocated data of type `TD` that is modified
"""
function interp_spray!(data::TD, dataout::TD, attrib=:interp, Battrib=:B1; pa=nothing)
	# check if datasets are similar
	nss = length(data.ageom)
	nr = data.ageom.nr
	xin=data.tgrid
	xout=dataout.tgrid
	if(pa===nothing)
		pa=Interpolation.Kernel([xin], [xout], :B1)
	end
	for ifield = 1:length(data.fields), iss = 1:nss
		dat=data.d[iss,ifield]
		dato=dataout.d[iss,ifield]
		for ir = 1:nr[iss]
			din=view(dat,:,ir)
			dout=view(dato,:,ir)
	 		Interpolation.interp_spray!(din, dout, pa, attrib)
		end
	end
	return dataout
end


"""
Method used to preallocate `TD` with zeros.

# Arguments

* `fields::Vector{Symbol}` : number of components
* `tgrid` : time domain grid
* `ageom::AGeom` : acquisition ageometry

# Return

* data with zeros as `TD`
"""
function TD_zeros(fields::Vector{Symbol}, tgrid::StepRangeLen, ageom::AGeom)
	return TD([zeros(length(tgrid),ageom[iss].nr) for iss=1:length(ageom), ifield=1:length(fields)],fields,
	   deepcopy(tgrid),deepcopy(ageom)) 
end
function Base.fill!(data::TD, k::Float64)
	for iss=1:length(data.ageom), ifield=1:length(data.fields)
		fill!(data.d[iss,ifield],k) 
	end
end
function TD_zeros(d::TD)
	return TD([zeros(length(d.tgrid),d.ageom[iss].nr) for iss=1:length(d.ageom), ifield=1:length(d.fields)],d.fields,
	   deepcopy(d.tgrid),deepcopy(d.ageom)) 
end


"Same as `TD_zeros`, except for returning ones"
function TD_ones(fields::Vector{Symbol}, tgrid::StepRangeLen, ageom::AGeom) 
	return TD([ones(length(tgrid),ageom[iss].nr) for iss=1:length(ageom), ifield=1:length(fields)],
	   fields,deepcopy(tgrid),deepcopy(ageom)) 
end



# include rest of the files
for file in ["base", "statistics", "processing", "misfits", "weights"]   
	fn=joinpath(@__DIR__, string(file,".jl"))
	include(fn)
	#Revise.track(@__MODULE__,fn)
end


#=
function DDecon(d::TD, wav::AbstractVector{Float64}, ϵ=1e-2)

	dout=TD_zeros(d)
	ntd=length(dout.tgrid)
	wavv=deepcopy(wav);

	paD=Decon.ParamD(ntd=ntd,nts=length(wav), s=wavv)

	paD.ϵ=ϵ

	DDecon!(dout, d, paD)
	return dout
end


function DDecon!(dataout::TD, data::TD, paD)
	nr = data.ageom.nr;	nss = data.ageom.nss;	nt = length(data.tgrid);
	for ifield = 1:length(data.fields), iss = 1:nss
		dd=data.d[iss, ifield]
		ddo=dataout.d[iss, ifield]
		for ir = 1:nr[iss]
			for it in 1:nt
				paD.d[it]=dd[it,ir]
			end
			Decon.mod!(paD)
			for it in 1:nt
				ddo[it,ir]=paD.g[it]
			end
		end
	end
	return dataout
end

=#


end # module
	=#
