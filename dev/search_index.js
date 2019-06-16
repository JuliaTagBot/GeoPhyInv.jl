var documenterSearchIndex = {"docs":
[{"location":"#The-Expt-Datatype-1","page":"Home","title":"The Expt Datatype","text":"","category":"section"},{"location":"#","page":"Home","title":"Home","text":"The methods in this package numerically solve some differential equations commonly faced in geophysical inverse problems. The functionality of this package revolves around the mutable Expt types. Firstly, most of the memory necessary to perform a given experiment is allocated while creating the Expt variables. Then these variables are input to in-place functions (e.g., mod!)  which as per Julia convention ends with an exclamation mark, to actually perform the experiment task. For example, the current Expt types within the realm of this package include:","category":"page"},{"location":"#","page":"Home","title":"Home","text":"SeisForwExpt is the seismic (acoustic) forward modeling experiment  ;\nSeisInvExpt is the type for seismic inversion experiment, including migration;\nPoissonExpt is type for the solving the Poisson experiment.","category":"page"},{"location":"#","page":"Home","title":"Home","text":"To get started, as an example, simply load a seismic inversion experiment already defined in our package gallery into REPL:","category":"page"},{"location":"#","page":"Home","title":"Home","text":"using GeoPhyInv # load GIPh (after installation)\npaE=GIPh.Gallery.SeisInvExpt(:pizza); # \"pizza\" is the name of the experiment","category":"page"},{"location":"Fdtd/intro/#","page":"Introduction","title":"Introduction","text":"A forward experiment, where the seismic data are generated using some models and acquisition parameters from our gallery. Forward modeling consists of a finite-difference simulation of the acoustic wave-equation.","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"EditURL = \"https://github.com/TRAVIS_REPO_SLUG/blob/master/\"","category":"page"},{"location":"Fdtd/reuse_expt/#Load-packages-1","page":"Basic usage","title":"Load packages","text":"","category":"section"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"using GeoPhyInv\nusing Statistics\nusing Plots\n\n\nmodel=GIPh.Gallery.Seismic(:acou_homo1); # load a homogeneous model\nGIPh.Models.Seismic_addon!(model, randn_perc=0.01); # add some random noise","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"a simple acquisition geometry","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"acqgeom=GeoPhyInv.Gallery.Geom(model.mgrid,:xwell);","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"plot the model and source, receivers","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"p1=JP.seismic(model)\nJP.geom!(acqgeom)\nplot(p1)","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"generate time grid","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"tgrid = range(0.0,stop=2.0,length=1000)","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"Ricker wavelet","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"wav = GeoPhyInv.Utils.Wavelets.ricker(10.0, tgrid, tpeak=0.25,);","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"distribute the same source wavelet to all the supsersources","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"acqsrc=GeoPhyInv.Acquisition.Src_fixed(acqgeom.nss,1,[:P],wav,tgrid);","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"create Fdtd.Param object to prepare forward modelling","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"npw corresponds to the number of independently propagating wavefields (1 in most cases)","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"Once the Param object is created, do the modelling \"without any memory allocations\" using mod!","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"pa=GeoPhyInv.Fdtd.Param(npw=1,model=model,\n\tacqgeom=[acqgeom], acqsrc=[acqsrc],\n\tsflags=[2], rflags=[1],\n\ttgridmod=tgrid, verbose=true);\n\n@time GeoPhyInv.Fdtd.mod!(pa);","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"plot a record after modelling","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"pdata=plot(pa.c.data[1].d[1,1])\nplot(pdata)","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"create new seismic model","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"model_new=J.Gallery.Seismic(:acou_homo1) # prepare another model\nJ.Models.Seismic_addon!(model_new, randn_perc=0.01)\nJ.Models.Seismic_addon!(model_new, constant_pert=0.03) # perturb the model\np2=JP.seismic(model_new) # plot new model\nJP.geom!(acqgeom)\nplot(p2)","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"Now, we the change the model in the Param object without memory allocation This routine can be used during FWI, where medium parameters are itertively updated in the same Fdtd.Param object","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"J.Fdtd.update_model!(pa.c, model_new)","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"run modelling now and plot data again","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"@time GeoPhyInv.Fdtd.mod!(pa);","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"plot a record after modelling","category":"page"},{"location":"Fdtd/reuse_expt/#","page":"Basic usage","title":"Basic usage","text":"plot!(pdata, pa.c.data[1].d[1,1])\nplot(pdata)","category":"page"},{"location":"Fdtd/create_snaps/#","page":"Generate snaps","title":"Generate snaps","text":"EditURL = \"https://github.com/TRAVIS_REPO_SLUG/blob/master/\"","category":"page"},{"location":"Fdtd/create_snaps/#","page":"Generate snaps","title":"Generate snaps","text":"A forward experiment, where the seismic data are generated using some models and acquisition parameters from our gallery. Forward modeling consists of a finite-difference simulation of the acoustic wave-equation. We specifically aim to save the snapshots, at given time steps in SeisForwExpt.","category":"page"},{"location":"Fdtd/create_snaps/#Loading-some-packages-1","page":"Generate snaps","title":"Loading some packages","text":"","category":"section"},{"location":"Fdtd/create_snaps/#","page":"Generate snaps","title":"Generate snaps","text":"using GeoPhyInv\nusing Statistics","category":"page"},{"location":"Fdtd/create_snaps/#Setting-up-the-variables-necessary-to-create-the-Expt-1","page":"Generate snaps","title":"Setting up the variables necessary to create the Expt","text":"","category":"section"},{"location":"Fdtd/create_snaps/#","page":"Generate snaps","title":"Generate snaps","text":"model=GIPh.Gallery.Seismic(:acou_homo1); # load a simple homogeneous acoustic model from the gallery\nGIPh.Models.Seismic_addon!(model, randn_perc=0.01); # add some random noise to the model\nacqgeom=GIPh.Gallery.Geom(model.mgrid,:xwell); # load a simple acquisition geometry using `mgrid` of the seismic model\ntgrid = range(0.0,stop=2.0,length=2000) # generate a time grid\nwav = GIPh.Utils.Wavelets.ricker(10.0, tgrid, tpeak=0.25,); # ricker wavelet\nacqsrc=GIPh.Acquisition.Src_fixed(acqgeom.nss,1,[:P],wav,tgrid); # distribute the same source wavelet to all the supsersources\n@info \"We are ready for the modeling.\"","category":"page"},{"location":"Fdtd/create_snaps/#Final-step-1","page":"Generate snaps","title":"Final step","text":"","category":"section"},{"location":"Fdtd/create_snaps/#","page":"Generate snaps","title":"Generate snaps","text":"One can plot the model, source and receivers using these commands: using Plots; p1=JP.seismic(model); JP.geom!(acqgeom); plot(p1); Now we have all the required variables to create SeisForwExpt object and prepare the forward modelling. While creating, we switched the snaps_flag on, and instructed recording field at tsnaps. Once the Expt object is created, do the modelling \"without approximately any memory allocations\" using mod!","category":"page"},{"location":"Fdtd/create_snaps/#","page":"Generate snaps","title":"Generate snaps","text":"paE=SeisForwExpt(model=model,\n\tacqgeom=[acqgeom], acqsrc=[acqsrc],\n\tsnaps_flag=true,\n\ttsnaps=[0.3, 0.4, 0.5],\n\ttgridmod=tgrid, verbose=true);\n\n@time mod!(paE);","category":"page"},{"location":"Fdtd/create_snaps/#Extracting-snaps-from-Expt-1","page":"Generate snaps","title":"Extracting snaps from Expt","text":"","category":"section"},{"location":"Fdtd/create_snaps/#","page":"Generate snaps","title":"Generate snaps","text":"snaps=paE[:snaps,1]; # extracting snaps of the first supersource\nsnaps=paE[:snaps,2]; # second supersource\n@info string(\"The dimensions of the snaps are (nz,nx,nt)=\", size(snaps))","category":"page"},{"location":"Fdtd/create_snaps/#","page":"Generate snaps","title":"Generate snaps","text":"We can now plot snapshots using these commands: p1=[heatmap(snaps[:,:,ii]) for ii in 1:3]; plot(p1..., layout=(1,3), aspect_ratio=:equal)","category":"page"},{"location":"Poisson/intro/#","page":"Introduction","title":"Introduction","text":"This module represents an explicit, direct sparse 2D finite-difference Poisson solver for heterogeneous media, i.e. media having spatially varying (space-dependent) medium parameters. Current implementation assumes Neumann boundary conditions at all the boundaries.","category":"page"},{"location":"Poisson/intro/#","page":"Introduction","title":"Introduction","text":"Consider the following Poisson experiment:","category":"page"},{"location":"Poisson/intro/#","page":"Introduction","title":"Introduction","text":"(σ(xz)) ψ(t) = (Q(xz)) p(t)","category":"page"},{"location":"Poisson/intro/#","page":"Introduction","title":"Introduction","text":"Q = k * Q_v  η","category":"page"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"EditURL = \"https://github.com/TRAVIS_REPO_SLUG/blob/master/\"","category":"page"},{"location":"Poisson/forw/#Loading-some-packages-1","page":"Record data","title":"Loading some packages","text":"","category":"section"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"using GeoPhyInv\nusing SparseArrays\nusing StatsBase\nusing LinearAlgebra\nusing Random\nusing ProgressMeter\nusing LinearAlgebra\nusing Test\nusing ForwardDiff\nusing Calculus","category":"page"},{"location":"Poisson/forw/#Solve-for-ψ-in-a-PoissonExpt-1","page":"Record data","title":"Solve for ψ in a PoissonExpt","text":"","category":"section"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"We start with the dimensions and spatial grids are allocated as follows.","category":"page"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"nx=21\nnz=21\nnt=4\nnznx=nz*nx\nmgrid=[range(-div(nz,2), step=1.0, length=nz), range(-div(nx,2), step=1.0, length=nx)]\ntgrid=range(0.0,step=0.5, length=nt)\n@info \"Grids are all set.\"","category":"page"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"Now lets allocate the inputs for a toy experiment. These medium parameters are used to generate the observed field ψ.","category":"page"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"Qv=abs.(randn(nz,nx))\nη=abs.(randn(nz,nx))\nk=abs.(randn(nz,nx))\nσ=abs.(randn(nz,nx))\np=randn(nz,nx,nt)\n@info \"Medium parameters allocated.\"","category":"page"},{"location":"Poisson/forw/#Acquisition-1","page":"Record data","title":"Acquisition","text":"","category":"section"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"Now, we will generate an acquisition geometry and allocate a projection matrix ACQ.","category":"page"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"acqgeom=GIPh.Acquisition.Geom_circ(nss=1,nr=30,rad=[5.,5.]);\nACQ=GIPh.Acquisition.ACQmat(acqgeom,mgrid);\n@info \"ACQ will be used to project ψ onto receivers.\"","category":"page"},{"location":"Poisson/forw/#Generate-PoissonExpt-and-then-applying-mod!-1","page":"Record data","title":"Generate PoissonExpt and then applying mod!","text":"","category":"section"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"This will first","category":"page"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"apply operator A=(Q(xz)) on a field p;\nthen apply ((σ(xz)))^-1 in order to solve for ψ;\nfinally, records ψ at the receiver locations to generate data.","category":"page"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"paE=PoissonExpt(p, tgrid, mgrid, Qv, k, η, σ, ACQ)\nmod!(paE)","category":"page"},{"location":"Poisson/forw/#Extracting-data-from-Expt-1","page":"Record data","title":"Extracting data from Expt","text":"","category":"section"},{"location":"Poisson/forw/#","page":"Record data","title":"Record data","text":"data=paE[:data]\n@info string(\"The dimensions of data are (nt,nr)=\",size(data))","category":"page"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"EditURL = \"https://github.com/TRAVIS_REPO_SLUG/blob/master/\"","category":"page"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"The linearized forward modeling operator F and its adjoint (aka Migration operator) are the building blocks of iterative optimization schemes. For the PoissonExpt, we have the functionality to compute F*x without explicitly storing the operator matrix (see LinearMaps.jl). The perturbed field δψ due to a perturbation in σ is given by","category":"page"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"δψ=-A¹(σ₀)A(δσ)ψ₀","category":"page"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"where","category":"page"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"(σ₀(xz)) ψ₀(t)=A(σ₀)ψ₀(t)=f(t)","category":"page"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"Lets start a tutorial.","category":"page"},{"location":"Poisson/test_born/#Load-some-packages-1","page":"Born map","title":"Load some packages","text":"","category":"section"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"using GeoPhyInv\nusing SparseArrays\nusing StatsBase\nusing LinearAlgebra\nusing Random\nusing ProgressMeter\nusing LinearAlgebra\nusing Test\nusing ForwardDiff\nusing Calculus\nusing LinearMaps","category":"page"},{"location":"Poisson/test_born/#Setting-up-the-spatial-and-temporal-grids-1","page":"Born map","title":"Setting up the spatial and temporal grids","text":"","category":"section"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"nx=21\nnz=21\nnt=4\nnznx=nz*nx\nmgrid=[range(-div(nz,2), step=1.0, length=nz), range(-div(nx,2), step=1.0, length=nx)]\ntgrid=range(0.0,step=0.5, length=nt)\n@info \"Grids are all set.\"","category":"page"},{"location":"Poisson/test_born/#Allocating-medium-parameters-1","page":"Born map","title":"Allocating medium parameters","text":"","category":"section"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"Qv=abs.(randn(nz,nx))\nη=abs.(randn(nz,nx))\nk=abs.(randn(nz,nx))\nσ=abs.(randn(nz,nx))\np=randn(nz,nx,nt)\n\nσobs=abs.(randn(nz,nx))\nQobs=abs.(randn(nz,nx))\nnr=10 # number of abstract receivers\nACQ=sprandn(nr,nz*nx,0.6); # choose a random acquisition operator\n@info \"We are ready for the PoissonExpt.\"","category":"page"},{"location":"Poisson/test_born/#Create-an-Expt,-and-then-extract-a-linear-forward-map-out-of-it-1","page":"Born map","title":"Create an Expt, and then extract a linear forward map out of it","text":"","category":"section"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"paE=PoissonExpt(p, tgrid, mgrid, Qv, k, η, σ, ACQ, σobs=σobs, Qobs=Qobs,)\nF=operator_Born(paE, σ); # extract the linearized forward operator from `Expt`\nGIPh.Utils.test_linearmap(F) # finally do some tests on the linearmap","category":"page"},{"location":"Poisson/test_born/#Usage-1","page":"Born map","title":"Usage","text":"","category":"section"},{"location":"Poisson/test_born/#","page":"Born map","title":"Born map","text":"δx=randn(size(F,2)) # random model pertubation\nδd=F*δx # corresponding pertubation in data\n@info string(\"Length of data: (nt*nr)=\",length(δd))","category":"page"}]
}