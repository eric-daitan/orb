# Copyright (c) Mainflux
# SPDX-License-Identifier: Apache-2.0

# Adapted for Orb project, modifications licensed under MPL v. 2.0:
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/. */

# expects to be set as env var
REF_TAG ?= develop
DEBUG_REF_TAG ?= develop-debug
PKTVISOR_TAG ?= latest-develop
PKTVISOR_DEBUG_TAG ?= latest-develop-debug
DOCKER_IMAGE_NAME_PREFIX ?= orb
DOCKERHUB_REPO = ns1labs
BUILD_DIR = build
SERVICES = fleet policies sinks sinker
DOCKERS = $(addprefix docker_,$(SERVICES))
DOCKERS_DEV = $(addprefix docker_dev_,$(SERVICES))
CGO_ENABLED ?= 0
GOARCH ?= amd64
ORB_VERSION = $(shell cat VERSION)
COMMIT_HASH = $(shell git rev-parse --short HEAD)

define compile_service
    echo "ORB_VERSION: $(ORB_VERSION)"
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) GOARM=$(GOARM) go build -mod=mod -ldflags "-extldflags "-static" -X 'github.com/ns1labs/orb/buildinfo.version=$(ORB_VERSION)'" -o ${BUILD_DIR}/$(DOCKER_IMAGE_NAME_PREFIX)-$(1) cmd/$(1)/main.go
endef

define compile_service_linux
	$(eval svc=$(subst docker_dev_,,$(1)))
    echo "ORB_VERSION: $(ORB_VERSION)"
	CGO_ENABLED=$(CGO_ENABLED) GOOS=linux GOARCH=$(GOARCH) GOARM=$(GOARM) go build -mod=mod -ldflags "-extldflags "-static" -X 'github.com/ns1labs/orb/buildinfo.version=$(ORB_VERSION)'" -o ${BUILD_DIR}/$(DOCKER_IMAGE_NAME_PREFIX)-$(svc) cmd/$(svc)/main.go
endef

define make_docker
	$(eval svc=$(subst docker_,,$(1)))

	docker build \
		--no-cache \
		--build-arg SVC=$(svc) \
		--build-arg GOARCH=$(GOARCH) \
		--build-arg GOARM=$(GOARM) \
		--tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-$(svc):$(REF_TAG) \
		--tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-$(svc):$(ORB_VERSION) \
		--tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-$(svc):$(ORB_VERSION)-$(COMMIT_HASH) \
		-f docker/Dockerfile .
endef

define make_docker_dev
	$(eval svc=$(subst docker_dev_,,$(1)))

	docker build \
		--no-cache \
		--build-arg SVC=$(svc) \
		--tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-$(svc):$(REF_TAG) \
		--tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-$(svc):$(ORB_VERSION) \
		--tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-$(svc):$(ORB_VERSION)-$(COMMIT_HASH) \
		-f docker/Dockerfile.dev ./build
endef

all: platform

.PHONY: all $(SERVICES) dockers dockers_dev ui services agent agent_bin

clean:
	rm -rf ${BUILD_DIR}

cleandocker:
	# Stops containers and removes containers, networks, volumes, and images created by up
#	docker-compose -f docker/docker-compose.yml down --rmi all -v --remove-orphans
	docker-compose -f docker/docker-compose.yml down -v --remove-orphans

ifdef pv
	# Remove unused volumes
	docker volume ls -f name=$(DOCKER_IMAGE_NAME_PREFIX) -f dangling=true -q | xargs -r docker volume rm
endif

test:
	go test -mod=mod -race -count 1 -tags test $(shell go list ./... | grep -v 'cmd')

proto:
	protoc --go_out=. --go_opt=paths=source_relative --go-grpc_out=. --go-grpc_opt=paths=source_relative policies/pb/policies.proto
	protoc --go_out=. --go_opt=paths=source_relative --go-grpc_out=. --go-grpc_opt=paths=source_relative fleet/pb/fleet.proto
	protoc --go_out=. --go_opt=paths=source_relative --go-grpc_out=. --go-grpc_opt=paths=source_relative sinks/pb/sinks.proto

$(SERVICES):
	$(call compile_service,$(@))

$(DOCKERS):
	$(call make_docker,$(@),$(GOARCH))

$(DOCKERS_DEV):
	$(call compile_service_linux,$(@))
	$(call make_docker_dev,$(@))

services: $(SERVICES)
dockers: $(DOCKERS)
dockers_dev: $(DOCKERS_DEV)

run:
	docker-compose -f docker/docker-compose.yml up -d

agent_bin:
	$(call compile_service_linux,agent)

agent:
	docker build \
	  --build-arg PKTVISOR_TAG=$(PKTVISOR_TAG) \
	  --tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-agent:$(REF_TAG) \
	  --tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-agent:$(ORB_VERSION) \
	  --tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-agent:$(ORB_VERSION)-$(COMMIT_HASH) \
	  -f agent/docker/Dockerfile .

agent_debug:
	docker build \
	  --build-arg PKTVISOR_TAG=$(PKTVISOR_DEBUG_TAG) \
	  --tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-agent:$(DEBUG_REF_TAG) \
	  -f agent/docker/Dockerfile .

ui:
	cd ui/ && docker build \
		--build-arg ENV_PS_SID=${PS_SID} \
		--build-arg ENV_PS_GROUP_KEY=${PS_GROUP_KEY} \
		--build-arg ENV=${ENVIRONMENT} \
		--tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-ui:$(REF_TAG) \
		--tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-ui:$(ORB_VERSION) \
		--tag=$(DOCKERHUB_REPO)/$(DOCKER_IMAGE_NAME_PREFIX)-ui:$(ORB_VERSION)-$(COMMIT_HASH) \
		-f docker/Dockerfile .

platform: dockers_dev docker_sinker agent ui
