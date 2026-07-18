/*
 * Reads all the contacts from the local store and forwards them to purple.
 *
 * The store is populated once during linking. Entries may be added and updated when receiving messages.
 */
pub async fn forward_contacts<C: presage::store::Store + 'static>(
    account: *mut crate::bridge_structs::PurpleAccount,
    manager: &mut presage::Manager<C, presage::manager::Registered>,
) {
    // Collect first so the store() borrow is released before we call manager.retrieve_profile_*
    // (which needs &mut manager) inside the loop below.
    let contacts: Vec<presage::model::contacts::Contact> = match manager.store().contacts().await {
        Err(err) => {
            crate::bridge::purple_debug(account, crate::bridge_structs::PURPLE_DEBUG_ERROR, format!("Unable to get contacts due to {err:?}\n"));
            return;
        }
        Ok(contacts) => contacts.flatten().collect(),
    };

    for presage::model::contacts::Contact {
        name,
        uuid,
        phone_number,
        profile_key,
        ..
    } in contacts
    {
        // webOS: on a linked (secondary) device the address-book `name` synced from the primary
        // phone is frequently empty, so the buddy would show only its raw UUID. Fall back to the
        // contact's own Signal profile name (what they set for themselves) when we have a valid
        // profile key, so buddies get a human alias. phone_number is still forwarded separately.
        let mut display_name = name;
        if display_name.is_empty() && profile_key.len() == presage::libsignal_service::zkgroup::PROFILE_KEY_LEN {
            if let Ok(profilek) = profile_key.try_into() {
                let profile_key = presage::libsignal_service::prelude::ProfileKey::create(profilek);
                match manager.retrieve_profile_by_uuid(uuid, profile_key).await {
                    Ok(profile) => {
                        if let Some(profile_name) = profile.name {
                            display_name = profile_name.to_string();
                        }
                    }
                    Err(err) => crate::bridge::purple_debug(account, crate::bridge_structs::PURPLE_DEBUG_INFO, format!("No profile name for {uuid}: {err:?}\n")),
                }
            }
        }

        let message = crate::bridge::Message {
            account: account,
            who: Some(uuid.to_string()),
            name: if display_name.is_empty() { None } else { Some(display_name) },
            phone_number: phone_number.map(|pn| pn.to_string()),
            ..Default::default()
        };
        crate::bridge::append_message(message);
    }
}

pub async fn get_group_members<C: presage::store::Store + 'static>(
    account: *mut crate::bridge_structs::PurpleAccount,
    manager: presage::Manager<C, presage::manager::Registered>,
    key: [u8; 32],
) -> Result<(), presage::Error<<C>::Error>> {
    match manager.store().group(key).await? {
        Some(group) => {
            let groups = vec![crate::bridge::Group::from_group(key, group)];
            crate::bridge::append_message(crate::bridge::Message {
                account: account,
                groups: groups,
                ..Default::default()
            });
        }
        None => {
            let key = hex::encode(key);
            crate::bridge::purple_debug(account, crate::bridge_structs::PURPLE_DEBUG_ERROR, format!("The group with key „{key}“ seems to be empty.\n"));
        }
    }
    Ok(())
}

pub async fn forward_groups<C: presage::store::Store + 'static>(
    account: *mut crate::bridge_structs::PurpleAccount,
    manager: &mut presage::Manager<C, presage::manager::Registered>,
) {
    match manager.store().groups().await {
        Err(err) => {
            crate::bridge::purple_debug(account, crate::bridge_structs::PURPLE_DEBUG_ERROR, format!("Unable to get groups due to {err:?}\n"));
        }
        Ok(groups) => {
            let groups: Vec<crate::bridge::Group> = groups.flatten().map(|(group_master_key, group)| crate::bridge::Group::from_group(group_master_key, group)).collect();
            crate::bridge::append_message(crate::bridge::Message {
                account: account,
                groups: groups,
                ..Default::default()
            });
        }
    }
}

pub async fn get_profile<C: presage::store::Store + 'static>(
    account: *mut crate::bridge_structs::PurpleAccount,
    manager: &mut presage::Manager<C, presage::manager::Registered>,
    uuid: presage::libsignal_service::prelude::Uuid,
) -> Result<presage::model::contacts::Contact, Box<dyn std::error::Error>> {
    let contact = manager.store().contact_by_id(&presage::libsignal_service::protocol::ServiceId::Aci(uuid.into())).await?;
    let mut contact = contact.ok_or("No contact information available.".to_string())?;

    // we have a contact, try to update their profile
    match contact.profile_key.len() {
        0 => crate::bridge::purple_debug(account, crate::bridge_structs::PURPLE_DEBUG_INFO, format!("Missing profile key for {uuid}.\n")),
        presage::libsignal_service::zkgroup::PROFILE_KEY_LEN => {
            let profilek = contact.profile_key.clone().try_into().map_err(|_| "Invalid profile key although length has been checked.")?;
            let profile_key = presage::libsignal_service::prelude::ProfileKey::create(profilek);
            let profile = manager.retrieve_profile_by_uuid(uuid, profile_key).await?;
            crate::bridge::purple_debug(account, crate::bridge_structs::PURPLE_DEBUG_INFO, format!("Profile for {uuid}: {profile:?}\n"));
            // webOS: prefer the contact's own profile name when the synced address-book name is
            // empty, so the get_info popup (and the returned contact) carries a human name.
            if contact.name.is_empty() {
                if let Some(profile_name) = profile.name {
                    contact.name = profile_name.to_string();
                }
            }
        }
        l => crate::bridge::purple_debug(
            account,
            crate::bridge_structs::PURPLE_DEBUG_INFO,
            format!("Expected profile key length {}, got {l} for {uuid}.\n", presage::libsignal_service::zkgroup::PROFILE_KEY_LEN),
        ),
    }

    Ok(contact)
}
