import os
import socket
import time
import multiprocessing
import random

# --- CONFIGURATION ---
TOTAL_SAMPLES = 100_000_000  # 100 Million points

def monte_carlo_pi_part(n):
    """
    Calculates a fraction of Pi using random sampling.
    This function will run on individual CPU cores.
    """
    count = 0
    for _ in range(n):
        x = random.random()
        y = random.random()
        # If the point falls inside the unit circle
        if x*x + y*y <= 1:
            count += 1
    return count

def calculate_pi_distributed(total_samples):
    # 1. Identify the Hardware (The "Factory")
    # This proves code is running on the Server, not your PC
    host = socket.gethostname()
    cores = multiprocessing.cpu_count()
    
    print(f"\n" + "="*40)
    print(f"🏭 PROCESSING NODE: {host}")
    print(f"🧠 CPU CORES ENGAGED: {cores}")
    print(f"🚀 Job: Calculate Pi using {total_samples:,} samples")
    print("="*40 + "\n")

    # 2. Split the work across all available Epyc cores
    # This utilizes the multiprocessing power of your server
    pool = multiprocessing.Pool(processes=cores)
    samples_per_core = total_samples // cores
    
    start_time = time.time()
    
    # Map the work to the pool (Launch the swarm)
    print(f"⚡ Spawning {cores} worker processes...")
    results = pool.map(monte_carlo_pi_part, [samples_per_core] * cores)
    
    pool.close()
    pool.join()

    # 3. Aggregate results
    total_inside = sum(results)
    pi_estimate = (total_inside * 4) / total_samples
    
    end_time = time.time()
    duration = end_time - start_time

    # 4. Report
    print(f"✅ CALCULATION COMPLETE")
    print(f"π Estimate: {pi_estimate}")
    print(f"⏱️ Time taken: {duration:.4f} seconds")
    print(f"🔥 Throughput: {total_samples / duration:,.0f} samples/sec")
    
    return pi_estimate

if __name__ == "__main__":
    calculate_pi_distributed(TOTAL_SAMPLES)