import Foundation
#if canImport(FoundationXML)
  import FoundationXML
#endif

/// The few XML documents S3 sends (bucket listings, errors) as a small element tree.
struct S3XML {
  var name: String
  var text: String
  var elements: [S3XML]

  func child(_ name: String) -> S3XML? { elements.first { $0.name == name } }
  func children(_ name: String) -> [S3XML] { elements.filter { $0.name == name } }

  /// The document's root element, or nil if `data` isn't XML.
  static func parse(_ data: Data) -> S3XML? {
    guard !data.isEmpty else { return nil }
    let builder = Builder()
    let parser = XMLParser(data: data)
    parser.delegate = builder
    parser.shouldProcessNamespaces = true
    guard parser.parse() else { return nil }
    return builder.root
  }

  private final class Builder: NSObject, XMLParserDelegate {
    var stack: [S3XML] = []
    var root: S3XML?

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
      attributes: [String: String] = [:]
    ) {
      stack.append(S3XML(name: elementName, text: "", elements: []))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      guard !stack.isEmpty else { return }
      stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
      guard let element = stack.popLast() else { return }
      if stack.isEmpty {
        root = element
      } else {
        stack[stack.count - 1].elements.append(element)
      }
    }
  }
}
