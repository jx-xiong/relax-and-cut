# iterate instance name in the list
threads=4
nthreads=1

timestamp=$(date +"%Y-%m-%d %H:%M:%S")
echo "==========Running script on instance: $timestamp, threads: $threads, nThreads: $nthreads ==========" >> res_an_threads_${threads}_nthreads_${nthreads}.txt
for instance in $(cat instances.txt); do
  julia --project --threads=$threads test_cb_start.jl -dataset $instance -nInt 6 -nCont 6 -stepsize 6 -threads $nthreads 2>&1 | tee ./logs/rh/${instance}_threads_${threads}_nthreads_${nthreads}.log;
done

timestamp=$(date +"%Y-%m-%d %H:%M:%S")
echo "==========Running script on instance: $timestamp, threads: $threads, nThreads: $nthreads ==========" >> res_td_threads_${threads}_nthreads_${nthreads}.txt
for instance in $(cat instances.txt); do
  julia --project --threads=$threads test_baseline.jl -dataset $instance -threads $nthreads 2>&1 | tee ./logs/td/${instance}_threads_${threads}_nthreads_${nthreads}.log;
done


timestamp=$(date +"%Y-%m-%d %H:%M:%S")
echo "==========Running script on instance: $timestamp, nThreads: $nthreads ==========" >> res_uc_threads_${threads}_nthreads_${nthreads}.txt
for instance in $(cat instances.txt); do
  julia --project --threads=$threads test_uc.jl -dataset $instance -threads $nthreads 2>&1 | tee ./logs/uc/${instance}_threads_${threads}_nthreads_${nthreads}.log;
done


# julia --threads=8 test_cb2.jl -dataset case1354pegase -nInt 6 -nCont 6 -stepsize 6 -threads 1