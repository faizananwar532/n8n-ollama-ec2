# 🖼️ Automated Image Captioning Workflow with n8n, Ollama LLaVA & AWS

## 📋 Overview

This guide provides complete setup instructions for an automated image captioning system that:
- Monitors AWS S3 for new images
- Processes images using Ollama LLaVA model on GPU-enabled EC2
- Generates captions and saves results as CSV files
- Uploads results back to S3

## 🏗️ Architecture

```
S3 Input Bucket → n8n Workflow (EC2) → Ollama LLaVA (EC2) → CSV Generation → S3 Output Bucket
```

## 🔄 Complete Workflow Diagram

```
┌─────────────────┐    ┌──────────────┐    ┌──────────────────┐    ┌──────────────┐
│ Check S3 Every  │───▶│ List S3      │───▶│ Filter Image     │───▶│ Download     │
│ 5 Minutes       │    │ Images       │    │ Files            │    │ Image        │
│ (Schedule)      │    │ (AWS S3)     │    │ (Filter)         │    │ (AWS S3)     │
└─────────────────┘    └──────────────┘    └──────────────────┘    └──────────────┘
                                                                           │
                                                                           │
                                                                           │
                                                                           │
                                                                ┌──────────────────┐
                                                                │ Process Images   │
                                                                │ with Ollama      │
                                                                │ (HTTP Request)   │
                                                                │ **MANUAL SETUP** │
                                                                └──────────────────┘                      
                                                                           │
                                                                           │
┌─────────────────┐    ┌──────────────┐    ┌──────────────────┐            │
│ Upload CSV      │◀───│ Create CSV   │◀───│ Process Caption  │◀───────────┘
│ to S3           │    │ File         │    │ Data             │
│ (AWS S3)        │    │ (Code)       │    │ (Code)           │
└─────────────────┘    └──────────────┘    └──────────────────┘

```

**Key Components:**
- **🔄 Schedule Trigger**: Checks S3 every 5 minutes
- **📁 S3 Operations**: Lists, downloads, and uploads files
- **🔍 Image Filter**: Processes only image files (jpg, png, gif, etc.)
- **🤖 Ollama Integration**: **MANUALLY CREATED** HTTP Request node
- **📊 Data Processing**: Combines captions with filenames
- **📋 CSV Generation**: Creates structured output files

## 🚀 Prerequisites

- AWS Account with appropriate permissions
- Terraform installed
- SSH key pair for EC2 access
- Basic knowledge of n8n workflows

---

## 📦 Part 1: Infrastructure Setup with Terraform

### 1.1 AWS Infrastructure Components

- **EC2 Instance**: GPU-enabled (g4dn.xlarge) for Ollama LLaVA
- **S3 Buckets**: Input and output buckets for images and CSV files
- **Security Groups**: Allow HTTP, SSH, and n8n access
- **IAM Roles**: For S3 access permissions

### 1.2 Terraform Configuration

Create the following files in your terraform directory:

#### `main.tf`
```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

# Get latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Create Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}c"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

# Create Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Associate Route Table with Subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Create Security Group
resource "aws_security_group" "instance_sg" {
  name        = "${var.project_name}-sg"
  description = "Security group for EC2 instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS access"
  }

  ingress {
    from_port   = 5678
    to_port     = 5678
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "n8n access"
  }

  ingress {
    from_port   = 11434
    to_port     = 11434
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Ollama access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

# Create EC2 Instance
resource "aws_instance" "main" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public.id

  vpc_security_group_ids = [aws_security_group.instance_sg.id]
  key_name              = var.key_pair_name

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  user_data = file("${path.module}/setup.sh")

  tags = {
    Name = "${var.project_name}-instance"
  }
}

# Create Elastic IP
resource "aws_eip" "instance_eip" {
  domain = "vpc"
  tags = {
    Name = "${var.project_name}-eip"
  }
}

# Associate Elastic IP with EC2 Instance
resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.main.id
  allocation_id = aws_eip.instance_eip.id
}

# Output the Elastic IP
output "elastic_ip" {
  value       = aws_eip.instance_eip.public_ip
  description = "The Elastic IP address assigned to the instance"
}
```

#### `variables.tf`
```hcl
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_access_key" {
  description = "AWS Access Key ID"
  type        = string
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS Secret Access Key" 
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "n8n-ollama"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "g4dn.xlarge"
}

variable "key_pair_name" {
  description = "Name of the AWS key pair"
  type        = string
  default     = "private_key_name"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "root_volume_size" {
  description = "Size of the root volume in GB"
  type        = number
  default     = 30
}
```

#### `setup.sh` (Comprehensive Setup Script)
```bash
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

# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker

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
      
      # Execution settings
      - EXECUTIONS_PROCESS=main
      - EXECUTIONS_MODE=regular
      
      # Security
      - N8N_SECURE_COOKIE=false
      
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

sudo chown ubuntu:ubuntu /home/ubuntu/docker-compose.yml

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
      
      # Execution settings
      - EXECUTIONS_PROCESS=main
      - EXECUTIONS_MODE=regular
      
      # Security
      - N8N_SECURE_COOKIE=false
      
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
docker exec ollama ollama pull llava

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
```

#### Backend Configuration Files

Create `backend.tfvars`:
```hcl
bucket = "your-terraform-state-bucket"
key    = "n8n-ollama/terraform.tfstate"
region = "us-east-1"
```

Create `secret-input.tfvars`:
```hcl
aws_access_key = "xxx"
aws_secret_key = "xxx"
```

### 1.3 Deploy Infrastructure

```bash
# Initialize Terraform with backend configuration
terraform init -backend-config=backend.tfvars

# Plan and apply with secret variables
terraform plan -var-file=secret-input.tfvars
terraform apply -var-file=secret-input.tfvars
```

### 1.4 Post-Deployment Setup

1. **SSH into the EC2 instance**:
   ```bash
   ssh -i private_key_name.pem ubuntu@<ELASTIC_IP>
   ```

2. **Monitor the initial setup**:
   ```bash
   sudo tail -f /var/log/cloud-init-output.log
   ```

3. **Reboot after initial setup**:
   ```bash
   sudo reboot
   ```

4. **Run post-reboot setup**:
   ```bash
   ssh -i private_key_name.pem ubuntu@<ELASTIC_IP>
   cd /home/ubuntu
   ./post-reboot-setup.sh
   ```

5. **Verify GPU access**:
   ```bash
   nvidia-smi
   docker exec ollama nvidia-smi
   ```

---

## 🔧 Part 2: n8n Configuration

### 2.1 Access n8n Interface

1. **Get EC2 public IP** from Terraform outputs
2. **Access n8n**: `http://<EC2_PUBLIC_IP>:5678`
3. **Login credentials**: 
   - Username: `admin`
   - Password: `ASDqwe123!`

### 2.2 Configure AWS Credentials in n8n

1. **Navigate to**: Settings → Credentials
2. **Add New Credential**: 
   - Type: `AWS`
   - Name: `AWS Credentials`
   - ID: `aws-credentials`
3. **Configure**:
   ```
   Access Key ID: xxx
   Secret Access Key: xxx
   Region: us-east-1
   ```

---

## 🔄 Part 3: Workflow Creation

### 3.1 Import Base Workflow

1. **Download** the `image-caption-workflow-http.json` file
2. **Import into n8n**: 
   - Go to Workflows → Import from File
   - Select the downloaded JSON file
3. **Save** the imported workflow

### 3.2 **CRITICAL: Manual Ollama HTTP Request Node Setup**

⚠️ **IMPORTANT**: The base workflow file does NOT include the Ollama integration node. You MUST create this manually to complete the workflow.

#### 3.2.1 **Why Manual Setup is Required**

The "Process Images with Ollama" node is intentionally excluded from the base workflow because:
- Different users may have different EC2 IP addresses
- Ollama API endpoints vary by deployment
- Manual configuration ensures proper timeout and parameter settings

#### 3.2.2 **Step-by-Step Manual Node Creation**

1. **Open your imported workflow in n8n**
2. **Locate the gap** between "Download Image" and "Process Caption Data" nodes
3. **Click the "+" button** in the connection line between these nodes
4. **Search for "HTTP Request"** and select it
5. **Rename the node** to "Process Images with Ollama"

#### 3.2.3 **Critical Configuration Parameters**

**🌐 Request Settings:**
```
Method: POST
URL: http://52.200.89.241:11434/api/generate
```
*(Replace with your actual EC2 Elastic IP)*

**📝 Headers:**
```
Name: Content-Type
Value: application/json
```

**📦 Body Configuration:**
```
Body Content Type: JSON
Body: Specify Body Using Fields Below

Add these parameters:
┌─────────────┬───────────────────────────────────────────────────┐
│ Parameter   │ Value                                             │
├─────────────┼───────────────────────────────────────────────────┤
│ model       │ llava:latest                                      │
│ prompt      │ Describe this image briefly.                      │
│ stream      │ {{ false }}     ⚠️ BOOLEAN, NOT STRING            │
│ images      │ {{ [Object.values($input.item.binary)[0].data] }} │
└─────────────┴───────────────────────────────────────────────────┘
```

**⏱️ Timeout Settings:**
```
Timeout: 300000 (5 minutes - essential for LLaVA processing)
```

#### 3.2.4 **Connect the Nodes**

```
Download Image ──────▶ Process Images with Ollama ──────▶ Process Caption Data
    (AWS S3)              (HTTP Request - Manual)            (Code Node)
```

**Connection Steps:**
1. **Disconnect** the existing connection between "Download Image" and "Process Caption Data"
2. **Connect** "Download Image" output to "Process Images with Ollama" input
3. **Connect** "Process Images with Ollama" output to "Process Caption Data" input

#### 3.2.5 **Test the Manual Node**

Before running the full workflow:
1. **Execute** only the "Process Images with Ollama" node
2. **Check** the output contains a "response" field with caption text
3. **Verify** no timeout or connection errors occur

### 3.3 Complete Workflow Structure

```
1. Check S3 Every 5 Minutes (Schedule Trigger)
   ↓
2. List S3 Images (AWS S3 - Get All)
   ↓
3. Filter Image Files (Filter - Regex for image extensions)
   ↓
4. Split in Batches (Split in Batches - Batch Size: 1)
   ↓
5. Download Image (AWS S3 - Download)
   ↓
6. Generate Caption with Ollama (HTTP Request - Manual)
   ↓
7. Progress Tracking (Code Node - Track processing status)
   ↓
8. Process Caption Data (Code Node)
   ↓
9. Merge Results (Merge Node - Combine all processed images)
   ↓
10. Create CSV File (Code Node)
    ↓
11. Upload CSV to S3 (AWS S3 - Upload)
    ↓
12. Success Notification (Sticky Note)
```

---

## ⚙️ Part 4: Node Configurations

### 4.1 Schedule Trigger
```json
{
  "rule": {
    "interval": [
      {
        "field": "minutes",
        "minutesInterval": 5
      }
    ]
  }
}
```

### 4.2 List S3 Images
```json
{
  "authentication": "credentials",
  "region": "us-east-1",
  "operation": "getAll",
  "bucketName": "wills-image-testing",
  "returnAll": true
}
```

### 4.3 Filter Image Files
```json
{
  "conditions": {
    "conditions": [
      {
        "leftValue": "={{ $json.Key }}",
        "rightValue": "\\.(jpg|jpeg|png|gif|bmp|webp)$",
        "operator": {
          "type": "string",
          "operation": "regex"
        }
      }
    ]
  }
}
```

### 4.4 Split in Batches (NEW - OPTIMIZATION)
```json
{
  "batchSize": 1,
  "options": {
    "reset": false
  }
}
```

**Why This Matters:**
- **Progress Visibility**: See each image being processed in real-time
- **Error Isolation**: One failed image won't stop the entire batch
- **Resource Management**: Consistent GPU memory usage
- **Debugging**: Easier to identify problematic images

### 4.5 Download Image
```json
{
  "authentication": "credentials",
  "region": "us-east-1",
  "operation": "download",
  "bucketName": "wills-image-testing",
  "fileKey": "={{ $json.Key }}"
}
```

### 4.6 Generate Caption with Ollama (UPDATED - OPTIMIZATION)

**Enhanced Configuration:**
- **URL**: `http://ollama:11434/api/generate` (use container name for internal communication)
- **Method**: POST
- **Headers**: Content-Type: application/json
- **Body Parameters**:
  ```json
  {
    "model": "llava:7b-v1.6",
    "prompt": "Describe this image in detail, focusing on the main subjects, objects, colors, and scene composition.",
    "images": ["{{ Object.values($input.item.binary)[0].data }}"],
    "stream": false,
    "options": {
      "temperature": 0.1,
      "num_ctx": 2048,
      "num_predict": 256,
      "num_thread": 8
    }
  }
  ```
- **Timeout**: 300000ms (5 minutes)
- **Retry on Fail**: 2 attempts
- **Retry Interval**: 5000ms

**Performance Settings:**
- `temperature: 0.1`: More consistent, focused descriptions
- `num_ctx: 2048`: Adequate context window for image analysis
- `num_predict: 256`: Reasonable caption length limit
- `num_thread: 8`: Optimized for g4dn.xlarge CPU cores

### 4.7 Progress Tracking (NEW - OPTIMIZATION)
```javascript
// Progress tracking and data enhancement
const currentItem = $input.item(0);
const itemIndex = $input.context.itemIndex || 0;
const totalItems = $input.context.totalItems || 1;

// Log progress to console
console.log(`Processing image ${itemIndex + 1} of ${totalItems}`);
console.log(`Current image: ${currentItem.json.Key ? currentItem.json.Key.split('/').pop() : 'Unknown'}`);

// Extract caption from Ollama response
let caption = 'No caption generated';
let filename = 'unknown';

if (currentItem.json && currentItem.json.response) {
  caption = currentItem.json.response.trim();
}

// Get filename from S3 key
if (currentItem.json && currentItem.json.Key) {
  filename = currentItem.json.Key.split('/').pop();
}

// Return enhanced data with progress info
return [{
  json: {
    filename: filename,
    caption: caption,
    processed_at: new Date().toISOString(),
    full_path: currentItem.json.Key || filename,
    batchNumber: itemIndex + 1,
    totalBatches: totalItems,
    processingProgress: `${itemIndex + 1}/${totalItems}`
  }
}];
```

### 4.8 Process Caption Data (UPDATED)
```javascript
// Enhanced caption data processing with batch tracking
const currentItem = $input.item(0);

// Extract data from progress tracking node
const filename = currentItem.json.filename || 'unknown';
const caption = currentItem.json.caption || 'No caption generated';
const processedAt = currentItem.json.processed_at;
const batchNumber = currentItem.json.batchNumber;
const totalBatches = currentItem.json.totalBatches;

// Log processing status
console.log(`Processed batch ${batchNumber}/${totalBatches}: ${filename}`);

return [{
  json: {
    filename: filename,
    caption: caption,
    processed_at: processedAt,
    full_path: currentItem.json.full_path,
    batch_info: `${batchNumber}/${totalBatches}`
  }
}];
```

### 4.9 Merge Results (NEW - OPTIMIZATION)
```json
{
  "mode": "keepKeyMatches",
  "options": {}
}
```

**Purpose**: Combines all individually processed images back into a single dataset for CSV creation.

### 4.10 Create CSV File (UPDATED)
```javascript
// Create CSV content from all processed image data
const allItems = $input.all();

// CSV headers with enhanced metadata
const headers = ['filename', 'caption', 'processed_at', 'batch_info', 'full_path'];
let csvContent = headers.join(',') + '\n';

// Add data rows
for (const item of allItems) {
  const row = [
    `"${item.json.filename}"`,
    `"${item.json.caption.replace(/"/g, '""')}"`, // Escape quotes in caption
    `"${item.json.processed_at}"`,
    `"${item.json.batch_info || 'N/A'}"`,
    `"${item.json.full_path || item.json.filename}"`
  ];
  csvContent += row.join(',') + '\n';
}

// Generate filename with timestamp
const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, -5);
const csvFilename = `image-captions-${timestamp}.csv`;

// Add processing summary
const summary = `\n# Processing Summary\n# Total Images: ${allItems.length}\n# Generated: ${timestamp}\n# Processing Mode: Batch (1 image per batch)\n`;

return [{
  json: {
    csvContent: csvContent + summary,
    filename: csvFilename,
    totalImages: allItems.length,
    processingMode: 'optimized_batch'
  },
  binary: {
    data: {
      data: Buffer.from(csvContent, 'utf8').toString('base64'),
      mimeType: 'text/csv',
      fileName: csvFilename
    }
  }
}];
```

### 4.11 Upload CSV to S3
```json
{
  "authentication": "credentials",
  "region": "us-east-1",
  "operation": "upload",
  "bucketName": "will-csv-output",
  "fileKey": "={{ $json.filename }}",
  "binaryData": true,
  "binaryPropertyName": "data"
}
```

---

## ⚡ Part 4.5: Performance Optimization

### GPU Memory Management

Update your `docker-compose.yml` Ollama service with optimized settings:

```yaml
ollama:
  image: ollama/ollama
  container_name: ollama
  runtime: nvidia
  environment:
    - NVIDIA_VISIBLE_DEVICES=all
    - OLLAMA_NUM_PARALLEL=1        # Process one at a time for consistency
    - OLLAMA_MAX_LOADED_MODELS=1   # Keep only one model in memory
    - OLLAMA_GPU_LAYERS=35         # Maximize GPU utilization
    - OLLAMA_FLASH_ATTENTION=1     # Enable flash attention for efficiency
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
```

### Alternative: Parallel Processing (For Faster Processing)

If you want faster processing with some parallel capability:

1. **Increase Batch Size**: Set Split in Batches to `2` or `3`
2. **Update Ollama Environment**:
   ```yaml
   - OLLAMA_NUM_PARALLEL=2
   ```
3. **Increase Timeout**: Set HTTP Request timeout to `600000` (10 minutes)

### Performance Monitoring Commands

```bash
# Watch GPU usage in real-time
watch -n 2 nvidia-smi

# Monitor container resource usage
docker stats ollama n8n --no-stream

# Check processing logs
docker logs n8n -f | grep "Processing image"

# Monitor Ollama specific logs
docker logs ollama -f
```

### Expected Benefits

1. **📊 Progress Visibility**: See each image being processed in real-time
2. **🛡️ Better Error Handling**: One failed image won't stop the entire batch
3. **🔧 Resource Management**: Consistent GPU memory usage
4. **🐛 Enhanced Debugging**: Easier to identify problematic images
5. **📈 Scalability**: Can adjust batch size based on performance needs
6. **📝 Detailed Logging**: Track processing progress and performance metrics

### Performance Metrics

**Optimized Performance Expectations:**
- **Processing Time**: 2-3 minutes per image (down from 5+ minutes in batch mode)
- **GPU Utilization**: Consistent 80-90% (vs. sporadic 100% peaks)
- **Memory Usage**: Stable ~8GB VRAM usage
- **Error Recovery**: Individual image failures don't affect others
- **Progress Tracking**: Real-time status updates

---

## 🧪 Part 5: Testing

### 5.1 Upload Test Images

Upload sample images to your S3 input bucket:
```bash
aws s3 cp ./test-image1.jpg s3://wills-image-testing/
aws s3 cp ./test-image2.png s3://wills-image-testing/
```

### 5.2 Test Ollama Manually

```bash
curl -X POST http://<EC2_IP>:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llava:latest",
    "prompt": "Describe this image briefly.",
    "stream": false
  }'
```

### 5.3 Execute Workflow

1. **Manual Test**: Click "Execute Workflow" button
2. **Automatic**: Wait for 5-minute schedule trigger
3. **Monitor**: Check execution logs and outputs

### 5.4 Expected Output

CSV file in output bucket with format:
```csv
filename,caption,processed_at
"image1.jpg","A detailed description of the image content...","2025-06-03T03:25:48.159Z"
"image2.png","Another detailed description of the second image...","2025-06-03T03:25:48.159Z"
```

---

## 🚨 Troubleshooting

### Common Issues

#### 1. "Model not found" Error
```bash
# SSH into EC2 and check Ollama
ssh -i private_key_name.pem ubuntu@<EC2_IP>
docker exec -it ollama ollama list
docker exec -it ollama ollama pull llava:7b-v1.6
```

#### 2. Slow Processing Performance
**Issue**: Images taking too long to process
**Solutions**:
- Check GPU utilization: `nvidia-smi`
- Reduce batch size to 1 if using parallel processing
- Verify Ollama environment variables are set correctly
- Restart Ollama container: `docker restart ollama`

#### 3. Memory Issues
**Issue**: Out of memory errors or container crashes
**Solutions**:
```bash
# Check memory usage
free -h
docker stats --no-stream ollama

# Restart with optimized settings
cd /home/ubuntu
docker compose down
docker compose up -d
```

#### 4. Progress Not Updating
**Issue**: Can't see processing progress in n8n
**Solutions**:
- Check console logs in n8n execution view
- Ensure Split in Batches node is configured correctly
- Verify Progress Tracking node code is executed

#### 5. Batch Processing Stuck
**Issue**: Workflow stops between batches
**Solutions**:
```bash
# Check for hanging processes
docker exec ollama ps aux

# Restart Ollama if stuck
docker restart ollama

# Clear any stuck executions in n8n interface
```

#### 6. Container Communication Issues
**Issue**: n8n can't reach Ollama container
**Solutions**:
- Use container name `ollama` instead of IP in HTTP Request URL
- Verify both containers are on same network: `docker network ls`
- Check container connectivity: `docker exec n8n ping ollama`

### Performance Optimization Troubleshooting

#### Slow GPU Processing
```bash
# Check GPU status
nvidia-smi

# Verify GPU access in container
docker exec ollama nvidia-smi

# Check GPU memory usage
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
```

#### High CPU Usage
```bash
# Check CPU usage
htop

# Limit Ollama CPU threads
# Update docker-compose.yml:
# - OLLAMA_NUM_THREAD=4  # Reduce from 8 to 4
```

#### Memory Leaks
```bash
# Monitor memory over time
watch -n 5 'free -h && docker stats --no-stream'

# Restart containers if memory usage grows
docker compose restart
```

### Advanced Monitoring

#### Set Up Real-time Monitoring Dashboard

Create `monitor.sh`:
```bash
#!/bin/bash
echo "=== N8N + Ollama Performance Monitor ==="
echo "Press Ctrl+C to stop"
echo ""

while true; do
    clear
    echo "=== $(date) ==="
    echo ""
    echo "GPU Status:"
    nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits
    echo ""
    echo "Container Stats:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
    echo ""
    echo "Disk Usage:"
    df -h /home/ubuntu
    echo ""
    sleep 5
done
```

Run: `chmod +x monitor.sh && ./monitor.sh`

---

## 📊 Monitoring & Maintenance

### Logs Location
- **n8n Logs**: Available in n8n interface under Executions
- **Ollama Logs**: `docker logs <ollama_container_id>`
- **System Logs**: `/var/log/messages` on EC2

### Resource Monitoring
- **GPU Usage**: `nvidia-smi`
- **Memory**: `free -h`
- **Disk**: `df -h`
- **CPU**: `htop`

### Backup Strategy
- **Workflow Export**: Regularly export n8n workflows
- **Volume Backup**: Backup Docker volumes for persistence
- **S3 Versioning**: Enable versioning on S3 buckets

---

## 💡 Advanced Features

### Scaling Options
1. **Multiple EC2 Instances**: Load balance across multiple Ollama instances
2. **SQS Integration**: Use SQS for reliable message queuing
3. **Lambda Functions**: Serverless processing for lightweight tasks
4. **ECS/EKS**: Container orchestration for production environments

### Enhanced Monitoring
1. **CloudWatch**: Set up detailed monitoring and alerts
2. **SNS Notifications**: Email/SMS alerts for workflow failures
3. **Custom Metrics**: Track processing times and success rates

### Security Enhancements
1. **VPC**: Deploy in private subnet with NAT Gateway
2. **IAM Roles**: Least privilege access principles
3. **Security Groups**: Restrict access to necessary ports only
4. **SSL/TLS**: Use HTTPS for all communications

---

## 📚 Resources

- [n8n Documentation](https://docs.n8n.io/)
- [Ollama Documentation](https://ollama.ai/docs)
- [AWS S3 Documentation](https://docs.aws.amazon.com/s3/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/)
- [LLaVA Model Information](https://ollama.ai/library/llava)

---

## 🎯 Next Steps for You

Now that you have the complete setup guide, here's your action plan to get the image captioning workflow running:

### **Phase 1: Infrastructure Setup (30-45 minutes)**

#### ✅ **Step 1: Prepare Your Environment**
- [ ] Ensure you have AWS CLI configured locally
- [ ] Verify you have the `private_key_name.pem` key file
- [ ] Create a Terraform state S3 bucket (if using remote state)
- [ ] Update `backend.tfvars` with your state bucket name

#### ✅ **Step 2: Deploy Infrastructure**
```bash
cd terraform
terraform init -backend-config=backend.tfvars
terraform plan -var-file=secret-input.tfvars
terraform apply -var-file=secret-input.tfvars
```

#### ✅ **Step 3: Post-Deployment Setup**
```bash
# Note the Elastic IP from Terraform output
ssh -i private_key_name.pem ubuntu@<ELASTIC_IP>

# Monitor initial setup
sudo tail -f /var/log/cloud-init-output.log

# Reboot when setup completes
sudo reboot

# After reboot, run post-setup
ssh -i private_key_name.pem ubuntu@<ELASTIC_IP>
cd /home/ubuntu
./post-reboot-setup.sh

# Verify GPU access
nvidia-smi
docker exec ollama nvidia-smi
```

### **Phase 2: S3 Bucket Setup (5 minutes)**

#### ✅ **Step 4: Create and Configure S3 Buckets**
```bash
# Create buckets if they don't exist
aws s3 mb s3://wills-image-testing
aws s3 mb s3://will-csv-output

# Upload test images
aws s3 cp test-image1.jpg s3://wills-image-testing/
aws s3 cp test-image2.png s3://wills-image-testing/
```

### **Phase 3: n8n Workflow Configuration (15-20 minutes)**

#### ✅ **Step 5: Access n8n and Setup Credentials**
1. **Open**: `http://<ELASTIC_IP>:5678`
2. **Login**: admin / ASDqwe123!
3. **Add AWS Credentials**:
   - Go to Settings → Credentials
   - Add AWS credentials with your access keys
   - Set region to `us-east-1`

#### ✅ **Step 6: Import and Configure Workflow**
1. **Import** the `image-caption-workflow-http.json` file
2. **CRITICAL**: Add the manual Ollama HTTP Request node:
   - Insert between "Download Image" and "Process Caption Data"
   - Configure with your EC2 IP: `http://<ELASTIC_IP>:11434/api/generate`
   - Set timeout to 300000ms
   - Use `{{ false }}` for stream parameter (boolean, not string!)
3. **Save** the workflow

### **Phase 4: Testing and Validation (10-15 minutes)**

#### ✅ **Step 7: Test Individual Components**
```bash
# Test Ollama directly
curl -X POST http://<ELASTIC_IP>:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model": "llava:latest", "prompt": "Describe this image briefly.", "stream": false}'
```

#### ✅ **Step 8: Test Full Workflow**
1. **Manual Execution**: Click "Execute Workflow" in n8n
2. **Check Logs**: Monitor execution for any errors
3. **Verify Output**: Check S3 output bucket for CSV files
4. **Schedule Test**: Let it run automatically for one cycle

### **Phase 5: Production Monitoring (Ongoing)**

#### ✅ **Step 9: Monitor Performance**
- [ ] Check GPU utilization: `nvidia-smi`
- [ ] Monitor Docker containers: `docker ps`
- [ ] Review n8n execution logs
- [ ] Verify CSV output quality

#### ✅ **Step 10: Troubleshooting Checklist**
If something goes wrong, check:
- [ ] NVIDIA drivers: `nvidia-smi`
- [ ] Ollama model: `docker exec ollama ollama list`
- [ ] n8n connectivity to Ollama API
- [ ] AWS credentials in n8n
- [ ] S3 bucket permissions

### **Quick Reference Commands**

```bash
# SSH to EC2
ssh -i private_key_name.pem ubuntu@<ELASTIC_IP>

# Check services
docker ps
docker logs n8n
docker logs ollama

# GPU status
nvidia-smi

# Restart services if needed
cd /home/ubuntu
docker compose restart

# Pull latest LLaVA model
docker exec ollama ollama pull llava:latest
```

### **Expected Timeline**
- **Total Setup Time**: 1-2 hours (first time)
- **First Caption Generation**: ~2-3 minutes per image
- **Steady State**: Processes images every 5 minutes automatically

### **When You're Done**
You should have:
- ✅ GPU-enabled EC2 instance running n8n and Ollama
- ✅ Automated workflow checking S3 every 5 minutes
- ✅ LLaVA model generating image captions
- ✅ CSV files automatically uploaded to output S3 bucket
- ✅ Complete monitoring and troubleshooting capabilities

---

## 🤝 Support

For issues and questions:
1. Check the troubleshooting section above
2. Review n8n execution logs
3. Check Ollama container logs
4. Verify AWS credentials and permissions
5. Test individual components separately

---

**Document Version**: 1.0  
**Last Updated**: 2025-06-03  
**Created by**: AI Assistant for Image Captioning Workflow 