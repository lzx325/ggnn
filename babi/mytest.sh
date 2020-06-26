# th babi_train.lua -learnrate 0.01 -maxiters 100 -saveafter 100 \
# -ntrain 50 -nval 50 -outputdir exp_1/q4 -statedim 6 -nsteps 7 \
# -mode selectnode -datafile data/processed_1/train/4_graphs.txt

# th babi_train.lua -learnrate 0.01 -maxiters 400 -saveafter 100 \
#  -ntrain 50 -nval 50 -statedim 3 -annotationdim 2 -outputdir exp_1/q18 -statedim 5 -nsteps 7 -mb 11\
#   -mode classifygraph -datafile data/processed_1/train/18_graphs.txt

# th babi_train.lua -learnrate 0.005 -momentum 0.9 -maxiters 1000 -saveafter 1000 -ntrain 50 -nval 50 -statedim 10\
#  -annotationdim 3 -outputdir exp_1/q19/1 -mode shareprop_seqclass\
#  -datafile data/processed_1/train/19_graphs.txt

 th seq_train.lua -learnrate 0.002 -momentum 0.9 -mb 10 -maxiters 700 -statedim 20 -ntrain 50 -nval 50\
  -annotationdim 10 -outputdir exp_1/seq4 -mode shareprop_seqnode -mb 11\
   -datafile data/extra_seq_tasks/fold_1/noisy_parsed/train/4_graphs.txt