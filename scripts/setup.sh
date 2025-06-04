#!/bin/bash

# Exit on any error
set -e

echo "Starting setup..."

# Clean up any existing NVIDIA installations
echo "Cleaning up existing NVIDIA installations..."
sudo apt-get remove --purge -y "*nvidia*" "*cuda*" || true
sudo apt-get autoremove -y
sudo apt-get clean
sudo rm -rf /var/lib/dkms/nvidia*
sudo rm -f /var/crash/nvidia*
sudo dpkg --configure -a

# Update system and install basic utilities
echo "Updating system packages..."
sudo apt-get update
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    gnupg \
    wget \
    build-essential \
    ubuntu-drivers-common

# Install NVIDIA drivers using ubuntu-drivers
echo "Installing NVIDIA drivers..."
sudo ubuntu-drivers autoinstall

# Install Docker
echo "Installing Docker..."
# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker packages
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start Docker service
sudo systemctl enable docker
sudo systemctl start docker

# Install NVIDIA Container Toolkit
echo "Installing NVIDIA Container Toolkit..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker

# Configure Docker daemon for NVIDIA
echo "Configuring Docker daemon for NVIDIA..."
sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF

# Restart Docker daemon
sudo systemctl restart docker

# Add current user to docker group
sudo usermod -aG docker ubuntu

# Create directories with correct permissions
echo "Setting up directories..."
sudo mkdir -p /home/ubuntu/n8n-data
sudo mkdir -p /home/ubuntu/n8n-files
sudo mkdir -p /home/ubuntu/ollama-data
sudo chown -R ubuntu:ubuntu /home/ubuntu/n8n-data
sudo chown -R ubuntu:ubuntu /home/ubuntu/n8n-files
sudo chown -R ubuntu:ubuntu /home/ubuntu/ollama-data

# Create initial docker-compose.yml without GPU support
echo "Creating initial docker-compose.yml..."
cat << 'EOF' | sudo tee /home/ubuntu/docker-compose.yml > /dev/null
version: '3.8'

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      # Basic Authentication
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=ASDqwe123!
      
      # Host Configuration
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      
      # Environment
      - NODE_ENV=production
      - WEBHOOK_URL=http://52.200.89.241:5678/
      
      # Timezone
      - GENERIC_TIMEZONE=UTC
      - TZ=UTC
      
      # Security
      - N8N_SECURE_COOKIE=false
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      
    volumes:
      - /home/ubuntu/n8n-data:/home/node/.n8n
      - /home/ubuntu/n8n-files:/files
    networks:
      - n8n-network
    depends_on:
      - ollama
    user: "node"

  ollama:
    image: ollama/ollama
    container_name: ollama
    ports:
      - "11434:11434"
    volumes:
      - /home/ubuntu/ollama-data:/root/.ollama
    restart: unless-stopped
    networks:
      - n8n-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  n8n-network:
    driver: bridge
EOF

# Fix n8n data directory permissions
echo "Setting correct permissions for n8n data directory..."
sudo chmod 700 /home/ubuntu/n8n-data
sudo chown -R 1000:1000 /home/ubuntu/n8n-data

# Create post-reboot setup script
echo "Creating post-reboot setup script..."
cat << 'EOF' | sudo tee /home/ubuntu/post-reboot-setup.sh > /dev/null
#!/bin/bash

# Wait for NVIDIA drivers to be fully loaded
echo "Waiting for NVIDIA drivers to initialize..."
for i in {1..30}; do
    if nvidia-smi &>/dev/null; then
        echo "NVIDIA drivers initialized successfully"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "NVIDIA driver initialization timed out"
        exit 1
    fi
    echo "Waiting for NVIDIA drivers... attempt $i/30"
    sleep 2
done

# Verify NVIDIA Container Toolkit installation
echo "Verifying NVIDIA Container Toolkit..."
if ! command -v nvidia-container-toolkit &> /dev/null; then
    echo "NVIDIA Container Toolkit not found. Installing..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
fi

# Fix n8n data directory permissions
echo "Setting correct permissions for n8n data directory..."
sudo chmod 700 /home/ubuntu/n8n-data
sudo chown -R 1000:1000 /home/ubuntu/n8n-data

# Update docker-compose.yml with GPU support
echo "Updating docker-compose.yml with GPU support..."
cat << 'EOL' > /home/ubuntu/docker-compose.yml
version: '3.8'

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      # Basic Authentication
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=ASDqwe123!
      
      # Host Configuration
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      
      # Environment
      - NODE_ENV=production
      - WEBHOOK_URL=http://52.200.89.241:5678/
      
      # Timezone
      - GENERIC_TIMEZONE=UTC
      - TZ=UTC
      
      # Security
      - N8N_SECURE_COOKIE=false
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      
    volumes:
      - /home/ubuntu/n8n-data:/home/node/.n8n
      - /home/ubuntu/n8n-files:/files
    networks:
      - n8n-network
    depends_on:
      - ollama
    user: "node"

  ollama:
    image: ollama/ollama
    container_name: ollama
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
    ports:
      - "11434:11434"
    volumes:
      - /home/ubuntu/ollama-data:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    restart: unless-stopped
    networks:
      - n8n-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  n8n-network:
    driver: bridge
EOL

# Restart docker compose with GPU support
echo "Restarting services with GPU support..."
cd /home/ubuntu
docker compose down
docker compose up -d

# Verify Ollama has GPU access
echo "Verifying Ollama GPU access..."
sleep 10
if ! docker exec ollama nvidia-smi &>/dev/null; then
    echo "Warning: Ollama container cannot access GPU. Please check nvidia-docker installation."
    exit 1
else
    echo "Ollama GPU access verified successfully!"
fi

# Pull LLaVA model
echo "Pulling LLaVA model..."
docker exec ollama ollama pull llava:7b-v1.6

echo "Post-reboot setup complete!"
EOF

# Set proper ownership and permissions for post-reboot script
sudo chown ubuntu:ubuntu /home/ubuntu/post-reboot-setup.sh
sudo chmod +x /home/ubuntu/post-reboot-setup.sh

echo "Installation complete! Please wait a few minutes for all services to start."
echo "A reboot is required to complete the NVIDIA driver installation."
echo "After reboot, please run:"
echo "1. cd /home/ubuntu"
echo "2. ./post-reboot-setup.sh"
echo "3. Check NVIDIA driver: nvidia-smi"
echo "4. Access n8n at: http://52.200.89.241:5678"
echo "   - Username: admin"
echo "   - Password: ASDqwe123!"

echo "Please run: sudo reboot"