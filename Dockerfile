# Obraz Node.js w wersji 24-alpine jako bazowy obraz do budowania aplikacji
FROM node:24-alpine AS builder

# Katalog roboczy dla procesu budowania
WORKDIR /build

# Kopiujemy plik zależności
COPY package.json .

# Instalujemy zależności i budujemy aplikację
RUN npm install --production && npm cache clean --force

# Kopiujemy resztę plików źródłowych do katalogu roboczego
COPY src/ ./src/

# Obraz Node.js w wersji 24-alpine jako finalny obraz do uruchomienia aplikacji
FROM node:24-alpine

# Metadane OCI
LABEL org.opencontainers.image.authors="Dominik Blaziak"

# Aktualizacja systemu i instalacja curl dla healthcheck
RUN apk update && apk upgrade --no-cache && apk add --no-cache curl

# Tworzymy użytkownika i grupę, aby aplikacja nie była uruchamiana jako root
RUN addgroup -S nodeapp && adduser -S nodeapp -G nodeapp

# Przełączamy się na użytkownika nodeapp
USER nodeapp

# Ustawiamy katalog roboczy dla aplikacji
WORKDIR /home/nodeapp/app

# Kopiujemy zbudowane pliki z etapu buildera do finalnego obrazu
COPY --from=builder --chown=nodeapp:nodeapp /build/node_modules ./node_modules
COPY --from=builder --chown=nodeapp:nodeapp /build/src ./src
COPY --from=builder --chown=nodeapp:nodeapp /build/package.json ./package.json

# Dodajemy HEALTHCHECK - sprawdzamy, czy aplikacja jest dostępna na porcie 3000
HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/ || exit 1

# Port, na którym nasza aplikacja będzie nasłuchiwać
EXPOSE 3000

# Uruchamiamy aplikację
ENTRYPOINT ["node", "src/bin/www"]