FROM mcr.microsoft.com/azure-cli:2.59.0-amd64

RUN apk add xmlstarlet
RUN apk add curl

WORKDIR /app

COPY . .

RUN chmod +x /app/scripts/deploy.sh