# iterate instance name in the list
threads=4
nthreads=4

# timestamp=$(date +"%Y-%m-%d %H:%M:%S")
# echo "==========Running script on instance: $timestamp, threads: $threads, nThreads: $nthreads ==========" >> res_an_threads_${threads}_nthreads_${nthreads}.txt
# echo "==========Running script on instance: $timestamp, threads: $threads, nThreads: $nthreads ==========" >> res_td_threads_${threads}_nthreads_${nthreads}.txt
# echo "==========Running script on instance: $timestamp, nThreads: $nthreads ==========" >> res_uc_threads_${threads}_nthreads_${nthreads}.txt
# for instance in $(cat instances.txt); do
#   julia --threads=$threads test_cb.jl -dataset $instance -nInt 24 -nCont 24 -stepsize 24 -threads $nthreads | tee ./logs/rh/${instance}_threads_${threads}_nthreads_${nthreads}.log;
#   julia --threads=$threads test_baseline.jl -dataset $instance -threads $nthreads| tee ./logs/td/${instance}_threads_${threads}_nthreads_${nthreads}.log;
#   julia --threads=$threads test_uc.jl -dataset $instance -threads $nthreads| tee ./logs/uc/${instance}_threads_${threads}_nthreads_${nthreads}.log;
# done



timestamp=$(date +"%Y-%m-%d %H:%M:%S")
echo "==========Running script on instance: $timestamp, threads: $threads, nThreads: $nthreads ==========" >> res_an_threads_${threads}_nthreads_${nthreads}.txt
for instance in $(cat instances.txt); do
  julia --threads=$threads test_cb.jl -dataset $instance -nInt 24 -nCont 24 -stepsize 24 -threads $nthreads | tee ./logs/rh/${instance}_threads_${threads}_nthreads_${nthreads}.log;
done

timestamp=$(date +"%Y-%m-%d %H:%M:%S")
echo "==========Running script on instance: $timestamp, threads: $threads, nThreads: $nthreads ==========" >> res_td_threads_${threads}_nthreads_${nthreads}.txt
for instance in $(cat instances.txt); do
  julia --threads=$threads test_baseline.jl -dataset $instance -threads $nthreads| tee ./logs/td/${instance}_threads_${threads}_nthreads_${nthreads}.log;
done


timestamp=$(date +"%Y-%m-%d %H:%M:%S")
echo "==========Running script on instance: $timestamp, nThreads: $nthreads ==========" >> res_uc_threads_${threads}_nthreads_${nthreads}.txt
for instance in $(cat instances.txt); do
  julia --threads=$threads test_uc.jl -dataset $instance -threads $nthreads| tee ./logs/uc/${instance}_threads_${threads}_nthreads_${nthreads}.log;
done


# for instance in $(cat instances.txt); do
#   # gunzip /home/jxxiong/.julia/packages/UnitCommitment/nnguY/instances/matpower/${instance}/2017-01-01.json.gz
#   python dataset_transformer.py --dataset $instance
# done