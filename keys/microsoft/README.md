# Microsoft Secure Boot objects

From https://github.com/microsoft/secureboot_objects at the commit in
`SOURCE_COMMIT`, following its `Templates/MicrosoftAndThirdParty.toml`
(the production template for systems that boot third-party code):

| File | Variable | Purpose |
|---|---|---|
| `KEK/kek-2k-ca-2023.der` | KEK | Microsoft Corporation KEK 2K CA 2023: authorizes Microsoft db/dbx updates |
| `db/windows-uefi-ca-2023.der` | db | Windows UEFI CA 2023: Windows boot media signed 2023+ |
| `db/uefi-ca-2023.der` | db | Microsoft UEFI CA 2023: third-party UEFI apps (shim, other Linux) |
| `db/option-rom-uefi-ca-2023.der` | db | Microsoft Option ROM UEFI CA 2023: GPU/storage/network option ROMs |
| `db/uefi-ca-2011.der` | db | Microsoft Corporation UEFI CA 2011: option ROMs and apps signed before 2023 |
| `dbx_x64.efiauth2` | dbx | Microsoft's revocation list, signed by KEK 2023 (append update) |

Deliberately left out, as in all of Microsoft's current templates except
"MostCompatible": Microsoft Corporation KEK CA 2011 (expired 2026-06-24) and
Microsoft Windows Production PCA 2011 (2011-signed Windows boot media).
