#!/bin/bash

##SBATCH -J AKSco #Single job name for the entire JobArray

##SBATCH -o slurm/AKSco_%A_%a.out #standard output

##SBATCH -e slurm/AKSco_%A_%a.err #standard error

#SBATCH -p general #partition

#SBATCH -t 00:10:00 #running time

#SBATCH --mail-type=BEGIN

#SBATCH --mail-type=END

#SBATCH --mail-user=iancze@gmail.com

#SBATCH --mem-per-cpu 10 #memory request per node

#SBATCH -n 20

./hostgen.sh

julia --machinefile hosts tests/parallel_test.jl
