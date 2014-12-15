# lnprob evaluation for V4046Sgr

const global keylist = Int[i for i=1:23]

# go through any previously created directories and remove them before the start
# of the run
function cleardirs!(keylist::Vector{Int})
    for key in keylist
        keydir = "jud$key"
        run(`rm -rf $keydir`)
    end
end

# Clear all directories
cleardirs!(keylist)

nchild = length(keylist)
addprocs(nchild)

@everywhere using constants
@everywhere using parallel
@everywhere using visibilities
@everywhere using image
@everywhere using gridding
@everywhere using model


@everywhere function initfunc(key)

    # Load the relevant chunk of the dataset
    dset = DataVis("data/V4046Sgr_fake.hdf5", key)

    # Create a directory where all RADMC files will reside and be driven from
    keydir = "jud$key"
    mkdir(keydir)

    # Copy all relevant configuration scripts to this subdirectory
    # these are mainly setup files which will not change
    run(`cp radmc3d.inp $keydir`)
    run(`cp lines.inp $keydir`)
    run(`cp numberdens_co.inp $keydir`)
    run(`cp molecule_co.inp $keydir`)

    # change the subprocess to reside in this directory for the remainder of the run
    # where it will drive its own independent RADMC3D process
    cd(keydir)

    # return the dataset
    return dset
end

@everywhere function f(dv::DataVis, key::Int, p::Parameters)

    # Unpack these variables from p
    incl = p.incl #33. # deg.
    vel = p.vel # km/s
    dpc = p.dpc # [pc] distance
    PA = 90 - p.PA # Position angle runs counter clockwise, due to looking at sky.
    npix = 96 # number of pixels, can alternatively specify x and y separately

    # Take this from the dataset
    lam0 =  dv.lam # [microns]

    # Run RADMC3D
    run(`radmc3d image incl $incl posang $PA vkms $vel npix $npix lambda $lam0`)

    # Read the RADMC3D image from disk (we should already be in sub-directory)
    im = imread()

    # Convert raw image to the appropriate distance
    skim = imToSky(im, dpc)

    # Apply the gridding correction function before doing the FFT
    corrfun!(skim, 1.0) #alpha = 1.0

    # FFT the appropriate image channel
    vis_fft = transform(skim)

    # Interpolate the `vis_fft` to the same locations as the DataSet
    mvis = ModelVis(dv, vis_fft)

    # Calculate chi^2 between these two
    return lnprob(dv, mvis)
end


pipes = initialize(nchild, keylist, initfunc, f)

# this function will run only on the main process
function fprob(p::Vector{Float64})

    # Here is where we make the distinction between a proposed vector of floats
    # (i.e., the parameters), and the object which defines all of the disk parameters
    # which every single subprocess will use

    # Parameters has the following definition (in model.jl)
    # M_star::Float64 # [g] stellar mass
    # r_c::Float64 # [cm] characteristic radius
    # T_10::Float64 # [K] temperature at 10 AU
    # q::Float64 # temperature gradient exponent
    # gamma::Float64 # surface temperature gradient exponent
    # M_CO::Float64 # [g] disk mass of CO
    # ksi::Float64 # [cm s^{-1}] microturbulence
    # dpc::Float64 # [pc] distance to system
    # incl::Float64 # [degrees] inclination 0 deg = face on, 90 = edge on.
    # PA::Float64 # [degrees] position angle (East of North)
    # vel::Float64 # [km/s] systemic velocity (positive is redshift/receeding)
    # mu_x::Float64 # [arcsec] central offset in RA
    # mu_y::Float64 # [arcsec] central offset in DEC

    # If we are going to fit with some parameters dropped out, here's the place to do it
    # the p... command "unrolls" the vector into a series of arguments.
    pars = Parameters(p...)

    # Compute parameter file using model.jl, write to disk
    write_model(pars)

    # Copy new parameter files to all subdirectories
    for key in keylist
        keydir = "jud$key"
        run(`cp numberdens_co.inp $keydir`)
        run(`cp gas_velocity.inp $keydir`)
        run(`cp gas_temperature.inp $keydir`)
    end


    distribute!(pipes, p)
    return gather!(pipes)
end

#From Rosenfeld et al. 2012, Table 1
M_star = 1.75 * M_sun # [g] stellar mass
r_c =  45. * AU # [cm] characteristic radius
T_10 =  115. # [K] temperature at 10 AU
q = 0.63 # temperature gradient exponent
gamma = 1.0 # surface temperature gradient exponent
M_CO = 2.8e-6 * M_sun # [g] disk mass of CO
ksi = 0.14e5 # [cm s^{-1}] microturbulence
incl = 33.5 # [degrees] inclination
#PA = 73.

println(fprob([M_star, r_c, T_10, q, gamma, M_CO, ksi, 73., incl, 73., 6., 0.0, 0.0]))

# wrapper for NLopt requires gradient as an argument (even if it's not used)
function fgrad(p::Vector, grad::Vector)
    val = fprob(p)
    println(p, " : ", val)
    return val
end
#
# function fp(p::Vector)
#     val = f(p)
#     println(p, " : ", val)
#     return val
# end

# # Now try optimizing the function using NLopt
# using NLopt
#
# starting_param = [1.3, 1.2, 0.7, 0.7]
#
# nparam = length(starting_param)
# opt = Opt(:LN_COBYLA, nparam)
#
# max_objective!(opt, fgrad)
# xtol_rel!(opt,1e-4)
#
# (optf,optx,ret) = optimize(opt, starting_param)
# println(optf, " ", optx, " ", ret)



# using LittleMC
#
# using Distributions
# using PDMats
#
# mc = MC(fp, 500, [1.2, 1.0, 1.0, 1.0], PDiagMat([0.03^2, 0.03^2, 0.01^2, 0.01^2]))
#
# start(mc)
#
#
# println(mean(mc.samples, 2))
# println(std(mc.samples, 2))
#
# runstats(mc)
#
# write(mc, "mc.hdf5")

quit!(pipes)