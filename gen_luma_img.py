import numpy as np
import matplotlib.pyplot as plt
import os

def gen_comparison(input_data_path, golden_path, rtl_path, save_path):
    if not os.path.exists(input_data_path):
        print(f"Error: {input_data_path} not found")
        return
    if not os.path.exists(golden_path):
        print(f"Error: {golden_path} not found")
        return
    if not os.path.exists(rtl_path):
        print(f"Error: {rtl_path} not found")
        return
    
    print(f"Loading Raw Input from {input_data_path}...")
    inp_data = np.loadtxt(input_data_path).astype(np.int16).reshape((128, 128))

    print(f"Loading Golden Reference from {golden_path}...")
    golden_data = np.loadtxt(golden_path).astype(np.int16).reshape((128, 128))
    
    print(f"Loading RTL Output from {rtl_path}...")
    # RTL output might be truncated if not fully simulated, but for a 128x128 CTU it should be 16384 samples
    rtl_data = np.loadtxt(rtl_path).astype(np.int16).reshape((128, 128))
    
    # Calculate Difference Maps
    rtl_gold_diff = np.abs(golden_data - rtl_data)
    max_rtl_gold_diff = np.max(rtl_gold_diff)

    inp_rtl_diff = np.abs(inp_data - rtl_data)
    max_inp_rtl_diff = np.max(inp_rtl_diff)
    
    fig, axes = plt.subplots(1, 4, figsize=(20, 5))
    
    # Panel 1: Golden Reference
    axes[0].imshow(golden_data, cmap='gray', vmin=0, vmax=255)
    axes[0].set_title("Golden Reference (VVC)")
    axes[0].axis('off')
    
    # Panel 2: RTL Output
    axes[1].imshow(rtl_data, cmap='gray', vmin=0, vmax=255)
    axes[1].set_title("RTL Filtered Output")
    axes[1].axis('off')
    
    # Panel 3: RTL vs Golden Difference (Verification)
    im2 = axes[2].imshow(rtl_gold_diff, cmap='hot', vmin=0, vmax=max(5, max_rtl_gold_diff))
    axes[2].set_title(f"RTL vs Golden (Max: {max_rtl_gold_diff})")
    axes[2].axis('off')
    plt.colorbar(im2, ax=axes[2], fraction=0.046, pad=0.04)

    # Panel 4: RTL vs Input Difference (Filter Activity)
    im3 = axes[3].imshow(inp_rtl_diff, cmap='magma', vmin=0, vmax=max(5, max_inp_rtl_diff))
    axes[3].set_title(f"Filter Activity (Max: {max_inp_rtl_diff})")
    axes[3].axis('off')
    plt.colorbar(im3, ax=axes[3], fraction=0.046, pad=0.04)
    
    plt.suptitle("VVC Luma Deblocking Filter: RTL Verification & Filter Activity")
    plt.tight_layout()
    plt.savefig(save_path)
    print(f"Comparison image saved to {save_path}")
    print(f"Max RTL vs Golden Diff: {max_rtl_gold_diff}")
    print(f"Max Filter Activity (RTL vs Input): {max_inp_rtl_diff}")

if __name__ == "__main__":
    gen_comparison('vectors/input_luma.txt', 'vectors/output_luma_qp45.txt', 'rtl_luma_out.txt', 'comparison.png')
