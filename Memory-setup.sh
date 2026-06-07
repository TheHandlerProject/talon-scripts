sudo bash << 'EOF'
# ── Step 1: Remove any leftover zram ──
for dev in /dev/zram*; do
    [[ -b "$dev" ]] && swapoff "$dev" 2>/dev/null; done
modprobe -r zram 2>/dev/null; modprobe zram num_devices=1

# ── Step 2: Set up 6GB zram (small = fast, no thrashing) ──
ZRAM_DEV=$(zramctl --find --size 6G --algorithm lz4)
mkswap "$ZRAM_DEV" && swapon --priority 100 "$ZRAM_DEV"
echo "zram: $(swapon --show | grep zram)"

# ── Step 3: Create 32GB disk swap ──
fallocate -l 32G /swapfile-ai || dd if=/dev/zero of=/swapfile-ai bs=1G count=32 status=progress
chmod 600 /swapfile-ai && mkswap /swapfile-ai && swapon --priority 10 /swapfile-ai
grep -q /swapfile-ai /etc/fstab || echo "/swapfile-ai none swap sw,pri=10 0 0" >> /etc/fstab

# ── Step 4: Tune kernel for AI workloads ──
sysctl -w vm.swappiness=10 vm.vfs_cache_pressure=50 vm.overcommit_memory=1
cat > /etc/sysctl.d/99-ai-memory.conf << 'SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.overcommit_memory=1
vm.dirty_ratio=5
SYSCTL

# ── Step 5: Configure Ollama if installed ──
if systemctl list-units --all | grep -q ollama; then
    mkdir -p /etc/systemd/system/ollama.service.d
    printf '[Service]\nEnvironment="OLLAMA_KEEP_ALIVE=5m"\nEnvironment="OLLAMA_MAX_LOADED_MODELS=1"\n' \
        > /etc/systemd/system/ollama.service.d/memory.conf
    systemctl daemon-reload && systemctl restart ollama
fi

echo "" && echo "=== Done. Memory state ===" && free -h && echo "" && swapon --show
EOF
