import Photos

extension PHAssetMediaType: @retroactive CustomStringConvertible {
  public var description: String {
    switch self {
    case .image: return "Image"
    case .video: return "Video"
    case .audio: return "Audio"
    case .unknown: return "Unknown"
    default: return "Unknown"
    }
  }
}

extension PHAssetCollectionType: @retroactive CustomStringConvertible {
  public var description: String {
    switch self {
    case .album: return "Album"
    case .smartAlbum: return "SmartAlbum"
    default: return "Unknown"
    }
  }
}

extension PHAssetCollectionSubtype: @retroactive CustomStringConvertible {
  public var description: String {
    switch self {
    case .albumRegular: return "AlbumRegular"
    case .albumSyncedEvent: return "AlbumSyncedEvent"
    case .albumSyncedFaces: return "AlbumSyncedFaces"
    case .albumSyncedAlbum: return "AlbumSyncedAlbum"
    case .albumImported: return "AlbumImported"
    case .albumMyPhotoStream: return "AlbumMyPhotoStream"
    case .albumCloudShared: return "AlbumCloudShared"
    case .smartAlbumGeneric: return "SmartAlbumGeneric"
    case .smartAlbumPanoramas: return "SmartAlbumPanoramas"
    case .smartAlbumVideos: return "SmartAlbumVideos"
    case .smartAlbumFavorites: return "SmartAlbumFavorites"
    case .smartAlbumTimelapses: return "SmartAlbumTimelapses"
    case .smartAlbumAllHidden: return "SmartAlbumAllHidden"
    case .smartAlbumRecentlyAdded: return "SmartAlbumRecentlyAdded"
    case .smartAlbumBursts: return "SmartAlbumBursts"
    case .smartAlbumSlomoVideos: return "SmartAlbumSlomoVideos"
    case .smartAlbumUserLibrary: return "SmartAlbumUserLibrary"
    case .smartAlbumSelfPortraits: return "SmartAlbumSelfPortraits"
    case .smartAlbumScreenshots: return "SmartAlbumScreenshots"
    case .smartAlbumDepthEffect: return "SmartAlbumDepthEffect"
    case .smartAlbumLivePhotos: return "SmartAlbumLivePhotos"
    case .smartAlbumAnimated: return "SmartAlbumAnimated"
    case .smartAlbumLongExposures: return "SmartAlbumLongExposures"
    case .smartAlbumUnableToUpload: return "SmartAlbumUnableToUpload"
    case .smartAlbumRAW: return "SmartAlbumRAW"
    case .smartAlbumCinematic: return "SmartAlbumCinematic"
    case .smartAlbumSpatial: return "SmartAlbumSpatial"
    case .smartAlbumScreenRecordings: return "SmartAlbumScreenRecordings"
    case .any: return "Any"
    default: return "Unknown"
    }
  }
}

extension PHCollectionListType: @retroactive CustomStringConvertible {
  public var description: String {
    switch self {
    case .momentList: return "MomentList"
    case .folder: return "Folder"
    case .smartFolder: return "SmartFolder"
    default: return "Unknown"
    }
  }
}

extension PHCollectionListSubtype: @retroactive CustomStringConvertible {
  public var description: String {
    switch self {
    case .momentListCluster: return "MomentListCluster"
    case .momentListYear: return "MomentListYear"
    case .regularFolder: return "RegularFolder"
    case .smartFolderEvents: return "SmartFolderEvents"
    case .smartFolderFaces: return "SmartFolderFaces"
    case .any: return "Any"
    default: return "Unknown"
    }
  }
}
