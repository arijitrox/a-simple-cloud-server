import torch
import time

def calculate_pi_gpu(total_samples=1_000_000_000, batch_size=100_000_000):
    """
    Calculates Pi using Monte Carlo simulation on the GPU.
    Uses batches to handle massive sample sizes (1B+) without OOM.
    """
    print(f"🔍 Checking hardware...")
    if not torch.cuda.is_available():
        print("❌ ROCm/CUDA not available. This script requires a GPU.")
        return

    # Select the first GPU
    device = torch.device("cuda")
    gpu_name = torch.cuda.get_device_name(0)
    gpu_count = torch.cuda.device_count()
    
    print(f"\n" + "="*50)
    print(f"🦖 GPU ENGINE ENGAGED: {gpu_name} (x{gpu_count})")
    print(f"🚀 Job: Calculate Pi using {total_samples:,} samples")
    print(f"📦 Batch Size: {batch_size:,}")
    print("="*50 + "\n")

    start_time = time.time()
    total_inside = 0

    # Process in batches to avoid VRAM overflow
    # 100M floats = ~800MB VRAM, perfectly safe for your cards
    for i in range(0, total_samples, batch_size):
        current_batch = min(batch_size, total_samples - i)
        
        # 1. Generate random points directly on GPU VRAM
        x = torch.rand(current_batch, device=device)
        y = torch.rand(current_batch, device=device)
        
        # 2. Vectorized Math: x^2 + y^2 <= 1
        # This runs on thousands of GPU cores simultaneously
        inside = (x.square() + y.square() <= 1).sum().item()
        total_inside += inside
        
        # Clean up tensors to free VRAM for next batch
        del x, y
        torch.cuda.empty_cache()

    end_time = time.time()
    duration = end_time - start_time
    
    pi_estimate = (total_inside * 4) / total_samples
    
    print(f"✅ CALCULATION COMPLETE")
    print(f"🎯 π Estimate: {pi_estimate}")
    print(f"⏱️ Time taken: {duration:.4f} seconds")
    print(f"🔥 Throughput: {total_samples / duration:,.0f} samples/sec")

if __name__ == "__main__":
    calculate_pi_gpu()