import torch
import os

print(f"🧠 PyTorch Version: {torch.__version__}")
print(f"🦖 ROCm Available: {torch.cuda.is_available()}")

if torch.cuda.is_available():
    device_count = torch.cuda.device_count()
    print(f"🔢 GPUs Detected: {device_count}")
    for i in range(device_count):
        print(f"   🔥 GPU {i}: {torch.cuda.get_device_name(i)}")
        
    # The Matrix Test (Pushes data to VRAM)
    try:
        x = torch.rand(10000, 10000).cuda()
        y = torch.rand(10000, 10000).cuda()
        z = torch.matmul(x, y)
        print("\n✅ Matrix Math Successful on GPU! (You are an AI God)")
    except Exception as e:
        print(f"\n❌ Math Error: {e}")
else:
    print("\n❌ Running on CPU. (Drivers not mapped correctly)")