import os
import sys

input_files = [
    ["tailopt/sum.pmrs", ""],
    ["tailopt/mts.pmrs", "--ver=5"],
    ["tailopt/mps.pmrs", "--ver=5"],
    ["zippers/sum.pmrs", ""],
    ["zippers/height.pmrs", ""],
    ["zippers/maxPathWeight.pmrs", ""],
    ["zippers/maxPathWeight2.pmrs", ""],
    ["ptree/sum.pmrs", ""],
    ["ptree/mul.pmrs", ""],
    ["ptree/maxheads.pmrs", ""],
    ["ptree/maxlast.pmrs", ""],
    ["ptree/maxsum.pmrs", ""],
    ["tree/sumtree.pmrs", ""],
    ["tree/maxtree.pmrs", ""],
    ["tree/mintree.pmrs", ""],
    ["tree/maxtree2.pmrs", ""],
    ["tree/maxPathWeight.pmrs", ""],
    ["list/sumhom.pmrs", ""],
    ["list/lenhom.pmrs", ""],
    ["list/prodhom.pmrs", ""],
    ["list/polyhom.pmrs", ""],
    ["list/hamming.pmrs", ""],
    ["list/maxhom.pmrs", ""],
    ["list/minhom.pmrs", ""],
    ["list/sndminhom.pmrs", ""],
    ["list/mtshom.pmrs", ""],
    ["list/mpshom.pmrs", ""],
    ["list/msshom.pmrs", ""],
    ["list/search.pmrs", ""],
    ["list/mts_and_mps_hom.pmrs", ""],
    ["list/issorted.pmrs", "--detupling-off"],
    ["tree/sorted.pmrs", "--detupling-off"],
    ["tree/mips.pmrs", ""],
    ["tree/mits.pmrs", ""]
]

root = os.getcwd()
path = os.path.join(root, "_build/default/bin/ReFunS.exe")

print("folder,file,# refinements, synthesis time")
sys.stdout.flush()

for filename_with_opt in input_files:
    filename = filename_with_opt[0]
    opt = filename_with_opt[1]
    os.system("%s %s -i %s" %
              (path, os.path.realpath(os.path.join("benchmarks", filename)), opt))
