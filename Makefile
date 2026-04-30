-include common.mk

update-common:
	wget -O common.mk https://raw.githubusercontent.com/ordinaryexperts/aws-marketplace-utilities/1.9.2/common.mk

deploy: build
	docker compose run -w /code/cdk --rm devenv cdk deploy \
	--require-approval never \
	--parameters AlbCertificateArn=arn:aws:acm:us-east-1:992593896645:certificate/943928d7-bfce-469c-b1bf-11561024580e \
	--parameters AlbIngressCidr=0.0.0.0/0 \
	--parameters AdminEmail=dylan@ordinaryexperts.com \
	--parameters AsgInstanceType=c7g.medium \
	--parameters AsgReprovisionString=20230517.6 \
	--parameters DnsHostname=peertube-${USER}.dev.patterns.ordinaryexperts.com \
	--parameters AsgAmiIdv300=ami-01957f524d64ff844 \
	--parameters DnsRoute53HostedZoneName=dev.patterns.ordinaryexperts.com
