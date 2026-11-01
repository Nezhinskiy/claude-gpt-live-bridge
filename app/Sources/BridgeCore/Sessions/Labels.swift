/// How sessions are named in the popover, the band and the voice's announcements.
public enum Labels {
  /// Each session's title. Sessions that share a title get ` · ` and the shortest id prefix,
  /// at least four characters, that tells them apart: `Example session · 0000`.
  public static func disambiguate(_ titles: [(SessionID, String)]) -> [SessionID: String] {
    var labels: [SessionID: String] = [:]
    for (title, sessions) in Dictionary(grouping: titles, by: \.1) {
      let ids = sessions.map(\.0.rawValue)
      guard ids.count > 1 else {
        labels[sessions[0].0] = title
        continue
      }
      let longest = ids.map(\.count).max() ?? 0
      let isUnique = { (width: Int) in Set(ids.map { $0.prefix(width) }).count == ids.count }
      let width = (4..<max(4, longest)).first(where: isUnique) ?? longest
      for (id, _) in sessions { labels[id] = "\(title) · \(id.rawValue.prefix(width))" }
    }
    return labels
  }
}
