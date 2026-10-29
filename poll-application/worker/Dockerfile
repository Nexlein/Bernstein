FROM maven:3.9-eclipse-temurin-25@sha256:93b8a14ea2f412782e4e842651273b4d903e35cc496284f178fbbe2d67d00976 AS build

WORKDIR /app

COPY pom.xml .
COPY src ./src
RUN mvn -q -B package

FROM eclipse-temurin:25-jre@sha256:78f1f183913482ef390c2722f46c3f0ce76ada341d69590e7c482ec943ee72d5

WORKDIR /app

COPY --from=build /app/target/worker-jar-with-dependencies.jar ./worker.jar

RUN useradd --system --uid 10001 app
USER 10001

EXPOSE 80

CMD ["java", "-jar", "worker.jar"]
