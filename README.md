# ${{ values.name }}

${{ values.description }}

## Deployment to AWS EKS

This application is configured to automatically deploy to AWS EKS when changes are pushed to the main branch.

### Deployment Architecture

- **Application Repository**: This repository contains the Node.js application code
- **Infrastructure Repository**: The AWS EKS infrastructure is managed in the [aws-eks](https://github.com/timesGH/aws-eks) repository
- **Integration**: GitHub Actions workflow in this repo builds the Docker image and triggers the EKS deployment workflow

### Automatic Deployment

When you push changes to the main branch, the following happens automatically:

1. GitHub Actions builds a Docker image for your application
2. The image is pushed to Amazon ECR
3. A repository dispatch event triggers the workflow in the aws-eks repository
4. The application is deployed to the EKS cluster

### Manual Deployment

You can also manually trigger the deployment:

1. Go to the "Actions" tab in this repository
2. Select the "Deploy Node.js App to EKS" workflow
3. Click "Run workflow"
4. Choose "update-app-only" or "full-deploy" (includes infrastructure updates)
5. Click "Run workflow"

### Required GitHub Secrets

This workflow requires the following secrets to be set in your repository:

- `AWS_ACCESS_KEY_ID`: AWS access key with permissions for ECR and EKS
- `AWS_SECRET_ACCESS_KEY`: Corresponding AWS secret key
- `AWS_REGION`: The AWS region where your cluster is deployed (e.g., us-east-1)
- `DISPATCH_TOKEN`: GitHub personal access token with `repo` scope for triggering workflows
- `CLUSTER_NAME`: The name of your EKS cluster
- `APP_NAME`: The name of your application (for Kubernetes resources)
- `CONTAINER_PORT`: The port your application listens on (default: 3000)

## Local Development

To run this application locally:

```bash
# Install dependencies
npm install

# Start the development server
npm start
```

The application will be available at http://localhost:${{ values.containerPort }}

## Dockerfile

The included Dockerfile builds the application for production use. To build and run locally:

```bash
# Build the image
docker build -t ${{ values.name | lower | replace(' ', '-') }}:latest .

# Run the container
docker run -p ${{ values.containerPort }}:${{ values.containerPort }} ${{ values.name | lower | replace(' ', '-') }}:latest
```
