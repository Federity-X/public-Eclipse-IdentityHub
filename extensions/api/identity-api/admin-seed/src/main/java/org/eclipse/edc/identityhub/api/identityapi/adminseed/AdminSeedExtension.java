/*
 *  Copyright (c) 2025 Contributors to the Eclipse Foundation
 *
 *  This program and the accompanying materials are made available under the
 *  terms of the Apache License, Version 2.0 which is available at
 *  https://www.apache.org/licenses/LICENSE-2.0
 *
 *  SPDX-License-Identifier: Apache-2.0
 *
 *  Contributors:
 *       Contributors to the Eclipse Foundation - initial API and implementation
 *
 */

package org.eclipse.edc.identityhub.api.identityapi.adminseed;

import org.eclipse.edc.identityhub.spi.participantcontext.IdentityHubParticipantContextService;
import org.eclipse.edc.identityhub.spi.participantcontext.model.KeyDescriptor;
import org.eclipse.edc.identityhub.spi.participantcontext.model.KeyPairUsage;
import org.eclipse.edc.identityhub.spi.participantcontext.model.ParticipantManifest;
import org.eclipse.edc.runtime.metamodel.annotation.Extension;
import org.eclipse.edc.runtime.metamodel.annotation.Inject;
import org.eclipse.edc.runtime.metamodel.annotation.Setting;
import org.eclipse.edc.spi.monitor.Monitor;
import org.eclipse.edc.spi.system.ServiceExtension;
import org.eclipse.edc.spi.system.ServiceExtensionContext;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.eclipse.edc.identityhub.api.identityapi.adminseed.AdminSeedExtension.NAME;

/**
 * Seeds an initial "super-admin" participant context on startup, solving the
 * bootstrap chicken-and-egg problem: the Identity Admin API requires an
 * x-api-key
 * that is returned from creating a participant, but creating a participant
 * requires
 * calling the API. This extension creates the first admin participant
 * programmatically and prints the API key to the log.
 */
@Extension(value = NAME)
public class AdminSeedExtension implements ServiceExtension {

    public static final String NAME = "Admin Seed Extension";

    private static final String DEFAULT_PARTICIPANT_ID = "super-admin";
    private static final String DEFAULT_KEY_ALGORITHM = "EdDSA";
    private static final String DEFAULT_KEY_CURVE = "Ed25519";

    @Setting(description = "Participant context ID for the seeded admin user", key = "edc.ih.admin.seed.participantId", required = false)
    private String participantId;

    @Setting(description = "DID for the seeded admin user. If set, takes precedence over did.web.host.", key = "edc.ih.admin.seed.did", required = false)
    private String did;

    @Setting(description = "DID web host (with port URL-encoded), e.g. 'localhost%3A10100'. " +
            "Used to auto-generate the DID as did:web:<host>:<participantId>.", key = "edc.ih.admin.seed.did.web.host", required = false)
    private String didWebHost;

    @Setting(description = "Whether to enable the admin seed extension. Set to false to disable seeding.", key = "edc.ih.admin.seed.enabled", defaultValue = "true")
    private boolean enabled;

    @Inject
    private IdentityHubParticipantContextService participantContextService;

    private Monitor monitor;

    @Override
    public String name() {
        return NAME;
    }

    @Override
    public void start() {
        if (!enabled) {
            monitor.info("[AdminSeed] Admin seeding is disabled (edc.ih.admin.seed.enabled=false).");
            return;
        }

        var pid = participantId != null && !participantId.isBlank() ? participantId : DEFAULT_PARTICIPANT_ID;
        var adminDid = did != null && !did.isBlank()
                ? did
                : didWebHost != null && !didWebHost.isBlank()
                        ? "did:web:" + didWebHost + ":" + pid
                        : "did:web:" + pid;

        // Check if the participant already exists
        var existing = participantContextService.getParticipantContext(pid);
        if (existing.succeeded() && existing.getContent() != null) {
            monitor.info("[AdminSeed] Admin participant '%s' already exists — skipping seed.".formatted(pid));
            return;
        }

        monitor.info("[AdminSeed] Creating admin participant '%s' with DID '%s' ...".formatted(pid, adminDid));

        var keyDescriptor = KeyDescriptor.Builder.newInstance()
                .keyId(pid + "-key")
                .privateKeyAlias(pid + "-alias")
                .resourceId(pid + "-resource")
                .keyGeneratorParams(Map.of("algorithm", DEFAULT_KEY_ALGORITHM, "curve", DEFAULT_KEY_CURVE))
                .active(true)
                .usage(Set.of(KeyPairUsage.values()))
                .build();

        var manifest = ParticipantManifest.Builder.newInstance()
                .participantContextId(pid)
                .did(adminDid)
                .active(true)
                .roles(List.of("admin"))
                .key(keyDescriptor)
                .build();

        var result = participantContextService.createParticipantContext(manifest);

        if (result.succeeded()) {
            var response = result.getContent();
            monitor.info("╔══════════════════════════════════════════════════════════════╗");
            monitor.info("║              ADMIN PARTICIPANT CREATED                      ║");
            monitor.info("╠══════════════════════════════════════════════════════════════╣");
            monitor.info("║  Participant ID : %s".formatted(pid));
            monitor.info("║  DID            : %s".formatted(adminDid));
            monitor.info("║  API Key        : %s".formatted(response.apiKey()));
            monitor.info("║  Client ID      : %s".formatted(response.clientId()));
            monitor.info("║  Client Secret  : %s".formatted(response.clientSecret()));
            monitor.info("╠══════════════════════════════════════════════════════════════╣");
            monitor.info("║  Use this API key in the 'x-api-key' header to call         ║");
            monitor.info("║  the Identity Admin API.                                    ║");
            monitor.info("╚══════════════════════════════════════════════════════════════╝");
        } else {
            monitor.severe("[AdminSeed] Failed to create admin participant: %s".formatted(result.getFailureDetail()));
        }
    }

    @Override
    public void initialize(ServiceExtensionContext context) {
        monitor = context.getMonitor().withPrefix("AdminSeed");
    }
}
