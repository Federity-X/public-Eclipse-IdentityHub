/*
 *  Copyright (c) 2025 Cofinity-X
 *
 *  This program and the accompanying materials are made available under the
 *  terms of the Apache License, Version 2.0 which is available at
 *  https://www.apache.org/licenses/LICENSE-2.0
 *
 *  SPDX-License-Identifier: Apache-2.0
 *
 *  Contributors:
 *       Cofinity-X - initial API and implementation
 *
 */


plugins {
    `java-library`
    id("application")
    alias(libs.plugins.shadow)
}

dependencies {
    runtimeOnly(project(":dist:bom:issuerservice-bom"))
    runtimeOnly(project(":dist:bom:issuerservice-feature-sql-bom"))
    runtimeOnly(project(":extensions:api:identity-api:admin-seed"))
    runtimeOnly(project(":extensions:api:identity-api:did-api"))
    runtimeOnly(project(":extensions:api:identity-api:identity-api-configuration"))
    runtimeOnly(libs.edc.vault.hashicorp)
}

application {
    mainClass.set("org.eclipse.edc.boot.system.runtime.BaseRuntime")
}

tasks.shadowJar {
    mergeServiceFiles()
    archiveFileName.set("issuer-service.jar")
    duplicatesStrategy = DuplicatesStrategy.INCLUDE
}

edcBuild {
    publish.set(false)
}
