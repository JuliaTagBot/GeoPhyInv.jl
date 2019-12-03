
# some model
mgrid = [range(0.0, stop=10.,step=0.05), range(0.0, stop=10.,step=0.05)];

model = Medium(mgrid);
vpb=[2100.,2200.];rhob=[2100., 2300.]
update!(model, [:vp,:rho], [vpb, rhob])
fill!(model)

nznx=prod(length.(model.mgrid))

for parameterization in [[:χKI, :χrhoI, :null],[:χKI, :null, :null],[:χvp, :χrho, :null],[:χvp, :null, :null]]
	δx1=randn(count(parameterization .≠ :null)*nznx)
	δxout1=zero(δx1)

	copyto!(δxout1, δx1, model, parameterization)

	δxout2=randn(size(δxout1));
	δx2=zero(δx1)
	pert_chainrule!(δx2, δxout2, model, parameterization)

	@test LinearAlgebra.dot(δxout2,δxout1) ≈ LinearAlgebra.dot(δx1,δx2)
end
