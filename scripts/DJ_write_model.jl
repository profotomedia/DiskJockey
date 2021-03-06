#!/usr/bin/env julia

# Generate a set of model and residual visibilities and then write them to UVHDF5 file format
# More about this format, including scripts to convert to UVFITS and CASA Measurement set,
# can be found at https://github.com/Astrochem/UVHDF5

using ArgParse

s = ArgParseSettings()
@add_arg_table s begin
    "--config"
    help = "a YAML configuration file"
    default = "config.yaml"
    "--out-model"
    help = "The file name to write out the model visibilities."
    default = "model.hdf5"
    "--out-resid"
    help = "The file name to write out the residual visibilities."
    default = "resid.hdf5"
end

parsed_args = parse_args(ARGS, s)

using DiskJockey.constants
using DiskJockey.image
using DiskJockey.model
using DiskJockey.visibilities
using DiskJockey.gridding

using HDF5

import YAML
config = YAML.load(open(parsed_args["config"]))

# The model writing is taken care of by `DJ_initialize.jl`, the RADMC-3D synthesis is taken care of by `DJ_plot_model.jl` and then this simply reads in the image, does FFT, downsamples, etc.

# read the wavelengths for all channels
fid = h5open(config["data_file"], "r")
nchan = length(read(fid["freqs"]))
close(fid)

# Read the parameters from the config file
pars = convert_dict(config["parameters"], config["model"])
grid = Grid(config["grid"])

# Mention the contribution of the prior to the lnprob
ln_prior = lnprior(pars, config["dpc_prior"]["mu"], config["dpc_prior"]["sig"], grid)

im = imread()
skim = imToSky(im, pars.dpc)
corrfun!(skim) # alpha = 1.0

# Determine dRA and dDEC from the image and distance
dRA = abs(skim.ra[2] - skim.ra[1])/2. # [arcsec] the half-size of a pixel
println("dRA is ", dRA, " arcsec")

# For *this purpose only*, read in the flagged data in addition to the unflagged data
# so that we can export a model for these otherwise flagged visibilities
dvarr = DataVis(config["data_file"], true)
# Do this as we do in `mach_three.jl`
for dset in dvarr
    # Conjugation is necessary for the SMA and ALMA
    visibilities.conj!(dset) # Swap UV convention
end

mvarr = Array(DataVis, nchan)
chi2s = Array(Float64, nchan)
lnprobs = Array(Float64, nchan)

for i=1:nchan
    dv = dvarr[i]

    # FFT the appropriate image channel
    vis_fft = transform(skim, i)

    # Interpolate the `vis_fft` to the same locations as the DataSet
    mvis = ModelVis(dv, vis_fft)

    # Apply the phase correction here, since there are fewer data points
    phase_shift!(mvis, pars.mu_RA + dRA, pars.mu_DEC - dRA)

    dvis = visibilities.ModelVis2DataVis(mvis)

    mvarr[i] = dvis

    chi2s[i] = visibilities.chi2(dv, mvis)
    lnprobs[i] = visibilities.lnprob(dv, mvis)
end

# Now generate the residual visibilities
rvarr = ResidVis(dvarr, mvarr)

# Now swap the model and residual visibilities back to ALMA/SMA convetion
for i=1:nchan
    visibilities.conj!(mvarr[i])
    visibilities.conj!(rvarr[i])
end

N = nchan * 2 * length(dvarr[1].VV)

# Only use the unmasked channels in the chi2 calculation
if haskey(config, "exclude")
    exclude = config["exclude"]
    # which channels of the dset to fit
    keylist = filter(x->(!in(x, exclude)), Int[i for i=1:nchan])
else
    keylist = Int[i for i=1:nchan]
end

println("Note: may include flagged visibilities!")
chi2s = chi2s[keylist]
# println("Chi^2 :", sum(chi2s))
println("Reduced Chi^2 ", sum(chi2s)/N)

# Calculate the lnprob between these two
lnprobs = lnprobs[keylist]

println("lnprior ", ln_prior)
println("lnlikelihood ", sum(lnprobs))
println("lnprob ", ln_prior + sum(lnprobs))

visibilities.write(mvarr, parsed_args["out-model"])
visibilities.write(rvarr, parsed_args["out-resid"])

# copy visibility flags from the original dataset to this new one
visibilities.copy_flags(config["data_file"], parsed_args["out-model"])
visibilities.copy_flags(config["data_file"], parsed_args["out-resid"])
