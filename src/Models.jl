module Models

import SIT.Grid
import SIT.IO
using Interpolations

"""
Data type fo represent a seismic model.
# Fields
* `vp0` :
* `vs0` :
* `ρ0` :
* `χvp` :
* `χvs` :
* `χρ` :
* `mgrid` :
"""
type Seismic
	vp0::Float64
	vs0::Float64
	ρ0::Float64
	χvp::Array{Float64}
	χvs::Array{Float64}
	χρ::Array{Float64}
	mgrid::Grid.M2D
end

"""
Get other dependent fields of a seismic model
"""
function Seismic_get(mod::Seismic, attrib::Symbol)
	K0 = mod.vp0 * mod.vp0 * mod.ρ0; K0I = K0^(-1.0);
	μ0 = mod.vs0 * mod.vs0 * mod.ρ0;
	vp = χ(mod.χvp, mod.vp0, -1)
	vs = χ(mod.χvs, mod.vs0, -1)
	ρ = χ(mod.χρ, mod.ρ0, -1)
	if(attrib == :ρI)
		return ρ.^(-1.0)
	elseif(attrib == :χρI)
		return χ(ρ.^(-1.0), mod.ρ0^(-1.0))
	elseif(attrib == :χK)
		return χ(vp .* vp .* ρ, K0) 
	elseif(attrib == :χμ)
		return χ(vs .* vs .* ρ, μ0) 
	elseif(attrib == :K0)
		return K0
	elseif(attrib == :μ0)
		return μ0
	elseif(attrib == :K0I)
		return K0I
	elseif(attrib == :χKI)
		K0 = vp0 * vp0 * ρ0; K0I = K0^(-1.0);
		return χ((vp .* vp .* ρ).^(-1), K0I) 
	elseif(attrib == :KI)
		return (vp .* vp .* ρ).^(-1)
	elseif(attrib == :K)
		return (vp .* vp .* ρ)
	else
		error("invalid attrib")
	end
end


"""
Return contrast model parameter using the
reference value.
"""
function χ(mod::Array{Float64}, mod0::Float64, flag::Int64=1)
	if(flag == 1)
		return	((mod - mod0) * mod0^(-1.0))
	elseif(flag == -1)
		return  (mod .* mod0 + mod0)
	end
end


"""
Add features to a model.

# Arguments
* `mod::Seismic` : model that is modified

# Keyword Arguments
* `circ_loc::Vector{Float64}=nothing` : location of center of perturbation
* `circ_rad::Float64=0.0` : radius of circular perturbation
* 

"""
function Seismic_addon(mod::Seismic; 
		       circ_loc::Array{Float64}=nothing,
		       circ_rad::Float64=0.0,
		       circ_pert::Float64=0.1,
		       fields::Vector{Symbol}=[:χvp,:χρ,:χvs]
		       )

	if(!(circ_loc == nothing))
		temp = [((sqrt((mod.mgrid.x[ix]-circ_loc[2])^2 + 
			(mod.mgrid.z[iz]-circ_loc[1])^2 ) <= circ_rad) ? circ_pert : 0.0)
		 for iz in 1:mod.mgrid.nz, ix in 1:mod.mgrid.nx  ]
	else
		temp = zeros(mod.mgrid.nz, mod.mgrid.nx)

	end

	mod_out = mod
	for field in fields
		setfield!(mod_out, field, (getfield(mod, field)+temp))
	end
	return mod_out
end

"""
Extend a seismic model into PML layers
"""
function Seismic_extend(mod::Seismic)

	vpex = extend(χ(mod.χvp, mod.vp0, -1),mod.mgrid.npml);
	vsex = extend(χ(mod.χvs, mod.vs0, -1),mod.mgrid.npml);
	ρex = extend(χ(mod.χρ, mod.ρ0, -1),mod.mgrid.npml);
	return Seismic(mod.vp0,
		 mod.vs0,
		 mod.ρ0,
		 χ(vpex,mod.vp0),
		 χ(vsex,mod.vs0),
		 χ(ρex,mod.ρ0),
		 Grid.M2D_extend(mod.mgrid))
end

"""
Extend a model on all four sides
"""
function extend(mod::Array{Float64,2}, np::Int64)
	nz = size(mod,1); nx = size(mod,2)
	modex = zeros(nz + 2*np, nx + 2*np)

	modex[np+1:np+nz,np+1:np+nx] = mod 
	modex[1:np,:] = repeat(modex[np+1,:], inner=np);
	modex[nz+1+np:end,:] = repeat(modex[nz+np,:],inner=np);
	modex[:,1:np] = repeat(modex[:,np+1], outer=np);
	modex[:,nx+1+np:end] = repeat(modex[:,nx+np], outer=np);
	return modex
end


"""
function to resample in the model domain
"""
function Seismic_resamp(mod::Seismic,
		mgrid::Grid.M2D
		)

	itpvp = interpolate((mod.mgrid.z, mod.mgrid.x),
		     mod.χvp, 
		     Gridded(Linear()))
	itpvs = interpolate((mod.mgrid.z, mod.mgrid.x),
		     mod.χvs, 
		     Gridded(Linear()))

	itpρ = interpolate((mod.mgrid.z, mod.mgrid.x),
		     mod.χρ, 
		     Gridded(Linear()))

	return Seismic(mod.vp0, mod.vs0, mod.ρ0, 
		itpvp[mgrid.z, mgrid.x], 
		itpvs[mgrid.z, mgrid.x],
		itpρ[mgrid.z, mgrid.x],
			      mgrid)

end
#
#macro inter


end # module