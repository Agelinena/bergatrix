# Proxy de saída do worker (smokescreen, da Stripe). Resolve o DNS e recusa
# qualquer destino em rede privada, loopback ou link-local: um link enviado
# pela interface não alcança o NAS, o roteador nem outros containers, nem
# por redirecionamento.

FROM golang:1.26.10-alpine AS build
ENV CGO_ENABLED=0 GOFLAGS=-trimpath
RUN go install -ldflags="-s -w" github.com/stripe/smokescreen@v0.1.0

FROM alpine:3.23
RUN apk add --no-cache ca-certificates
COPY --from=build /go/bin/smokescreen /usr/local/bin/smokescreen
USER 10001:10001
EXPOSE 4750
ENTRYPOINT ["smokescreen", "--listen-ip", "0.0.0.0", "--listen-port", "4750"]
