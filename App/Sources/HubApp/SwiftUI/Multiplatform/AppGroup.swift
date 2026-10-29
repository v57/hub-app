//
//  AppGroup.swift
//  Hub
//
//  The app group container (`group.dev.v57.hub`) the app shares with its extensions on Apple platforms. Elsewhere
//  there are no app groups and no extensions to share with: the lookup finds none, as on a build without the
//  entitlement.
//

import Foundation

#if !canImport(Darwin)
extension FileManager {
  func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? { nil }
}
#endif
