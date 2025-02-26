//  KeePassium Password Manager
//  Copyright © 2018-2022 Andrei Popleteev <info@keepassium.com>
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import AuthenticationServices

public enum OneDriveError: LocalizedError {
    case cancelledByUser
    case emptyResponse
    case misformattedResponse
    case cannotRefreshToken
    case serverSideError(message: String)
    case general(error: Error)
    
    public var errorDescription: String? {
        switch self {
        case .cancelledByUser:
            return "Cancelled by user." 
        case .emptyResponse:
            return "Server response is empty."
        case .misformattedResponse:
            return "Unexpected server response format."
        case .cannotRefreshToken:
            return "Cannot renew access token."
        case .serverSideError(let message):
            return message
        case .general(let error):
            return error.localizedDescription
        }
    }
}

public struct OneDriveDriveInfo {
    public enum DriveType: String, CustomStringConvertible {
        case personal = "personal"
        case business = "business"
        case sharepoint = "documentLibrary"
        public var description: String {
            switch self {
            case .personal:
                return LString.connectionTypeOneDrive
            case .business:
                return LString.connectionTypeOneDriveForBusiness
            case .sharepoint:
                return LString.connectionTypeSharePoint
            }
        }
    }
    
    public var id: String
    public var name: String
    public var type: DriveType
    public var ownerEmail: String?
}

/*
 This code includes parts of https:
 by GitHub user lithium03, published under the MIT license.
 */
final public class OneDriveManager: NSObject {
    public typealias TokenUpdateCallback = (OAuthToken) -> Void
    
    public static let shared = OneDriveManager()
    
    private let maxUploadSize = 60 * 1024 * 1024 
    
    private enum AuthConfig {
        static var clientID: String {
            switch BusinessModel.type {
            case .freemium:
                return "cd88bd1f-abdf-4d0f-921e-d8acbf02e240"
            case .prepaid:
                return "c3885b4b-5dac-43a6-af93-c869c1a8328b"
            }
        }
        static let scope = "user.read files.readwrite offline_access"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        static let apiEndPoint = "https://graph.microsoft.com/v1.0/me/drive"
        static let callbackURLScheme = "keepassium"
        static let redirectURI = "keepassium://onedrive-auth"
        static let authURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=\(clientID)&scope=\(scope)&response_type=code&redirect_uri=\(redirectURI)")!
        static let tokenRequestURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
    }
    
    private enum Keys {
        static let accessToken = "access_token"
        static let authorization = "Authorization"
        static let code = "code"
        static let contentLength = "Content-Length"
        static let contentRange = "Content-Range"
        static let contentType = "Content-Type"
        static let createdDateTime = "createdDateTime"
        static let driveType = "driveType"
        static let email = "email"
        static let error = "error"
        static let errorDescription = "error_description"
        static let expiresIn = "expires_in"
        static let id = "id"
        static let file = "file"
        static let folder = "folder"
        static let lastModifiedDateTime = "lastModifiedDateTime"
        static let message = "message"
        static let name = "name"
        static let owner = "owner"
        static let refreshToken = "refresh_token"
        static let size = "size"
        static let uploadUrl = "uploadUrl"
        static let user = "user"
        static let value = "value"
    }
    
    private var presentationAnchors = [ObjectIdentifier: Weak<ASPresentationAnchor>]()
    
    private lazy var urlSession: URLSession = {
        var config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = true
        config.multipathServiceType = .none
        config.waitsForConnectivity = false
        return URLSession(
            configuration: config,
            delegate: nil,
            delegateQueue: OneDriveManager.backgroundQueue
        )
    }()
    private static let backgroundQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.keepassium.OneDriveManager"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    
    override private init() {
        super.init()
    }
}

extension OneDriveManager {
    private func parseJSONResponse(
        operation: String,
        data: Data?,
        error: Error?
    ) -> Result<[String: Any], OneDriveError> {
        if let error = error {
            Diag.error("OneDrive request failed [operation: \(operation), message: \(error.localizedDescription)]")
            return .failure(.general(error: error))
        }
        guard let data = data else {
            Diag.error("OneDrive request failed: no data received [operation: \(operation)]")
            return .failure(.emptyResponse)
        }

        guard let json = parseJSONDict(data: data) else {
            Diag.error("OneDrive request failed: misformatted response [operation: \(operation)]")
            return .failure(.emptyResponse)
        }

        if let serverMessage = getServerErrorMessage(from: json) {
            Diag.error("OneDrive request failed: server-side error [operation: \(operation), message: \(serverMessage )]")
            return .failure(.serverSideError(message: serverMessage ))
        }
        return .success(json)
    }
    
    
    private func parseJSONDict(data: Data) -> [String: Any]? {
        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
            guard let json = jsonObject as? [String: Any] else {
                Diag.error("Unexpected JSON format")
                return nil
            }
            return json
        } catch {
            Diag.error("Failed to parse JSON data [message: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func getServerErrorMessage(from json: [String: Any]) -> String? {
        guard let errorObject = json[Keys.error] else { 
            return nil
        }
        guard let errorDict = errorObject as? [String: Any] else {
            return String(describing: errorObject)
        }
        Diag.error(errorDict.description)
        let message = errorDict[Keys.message] as? String
        return message
    }
}

extension OneDriveManager {
    private enum TokenOperation: CustomStringConvertible {
        case authorization(code: String)
        case refresh(token: OAuthToken)
        var description: String {
            switch self {
            case .authorization:
                return "tokenAuth"
            case .refresh:
                return "tokenRefresh"
            }
        }
    }
    
    public func authenticate(
        presenter: UIViewController,
        privateSession: Bool,
        completionQueue: OperationQueue = .main,
        completion: @escaping (Result<OAuthToken, OneDriveError>) -> Void
    ) {
        Diag.info("Authenticating with OneDrive")
        
        let webAuthSession = ASWebAuthenticationSession(
            url: AuthConfig.authURL,
            callbackURLScheme: AuthConfig.callbackURLScheme,
            completionHandler: { (callbackURL: URL?, error: Error?) in
                if let error = error as NSError? {
                    let isCancelled =
                        (error.domain == ASWebAuthenticationSessionErrorDomain) &&
                        (error.code == ASWebAuthenticationSessionError.canceledLogin.rawValue)
                    if isCancelled {
                        completionQueue.addOperation {
                            Diag.info("Authentication cancelled by user")
                            completion(.failure(.cancelledByUser))
                        }
                    } else {
                        completionQueue.addOperation {
                            Diag.error("Authentication failed [message: \(error.localizedDescription)]")
                            completion(.failure(.general(error: error)))
                        }
                    }
                    return
                }
                guard let callbackURL = callbackURL,
                      let urlComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                      let queryItems = urlComponents.queryItems
                else {
                    completionQueue.addOperation {
                        Diag.error("Authentication failed: empty or misformatted callback URL")
                        completion(.failure(.emptyResponse))
                    }
                    return
                }
                
                if let errorDescItem = queryItems.first(where: { $0.name == Keys.errorDescription}),
                   let errorDescription = errorDescItem.value?
                        .removingPercentEncoding?
                        .replacingOccurrences(of: "+", with: " ")
                {
                    completionQueue.addOperation {
                        Diag.error("Authentication failed: \(errorDescription)")
                        completion(.failure(.serverSideError(message: errorDescription)))
                    }
                    return
                }
                guard let codeItem = urlComponents.queryItems?.first(where: { $0.name == Keys.code }),
                      let authCodeString = codeItem.value
                else {
                    completionQueue.addOperation {
                        Diag.error("Authentication failed: OAuth token not found in response")
                        completion(.failure(.misformattedResponse))
                    }
                    return
                }
                self.getToken(
                    operation: .authorization(code: authCodeString),
                    completionQueue: completionQueue,
                    completion: completion
                )
            }
        )
        presentationAnchors[ObjectIdentifier(webAuthSession)] = Weak(presenter.view.window!)
        webAuthSession.presentationContextProvider = self
        webAuthSession.prefersEphemeralWebBrowserSession = privateSession

        webAuthSession.start()
    }
    
    private func getToken(
        operation: TokenOperation,
        completionQueue: OperationQueue,
        completion: @escaping (Result<OAuthToken, OneDriveError>) -> Void
    ) {
        Diag.debug("Acquiring OAuth token [operation: \(operation)]")
        var urlRequest = URLRequest(url: AuthConfig.tokenRequestURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: Keys.contentType)
        
        var postParams = [
            "client_id=\(AuthConfig.clientID)",
            "redirect_uri=\(AuthConfig.redirectURI)",
            "scope=\(AuthConfig.scope)",
        ]
        
        let refreshToken: String?
        switch operation {
        case .authorization(let authCode):
            refreshToken = nil
            postParams.append("code=\(authCode)")
            postParams.append("grant_type=authorization_code")
        case .refresh(let token):
            refreshToken = token.refreshToken
            postParams.append("refresh_token=\(token.refreshToken)")
            postParams.append("grant_type=refresh_token")
        }
        
        let postData = postParams
            .joined(separator: "&")
            .data(using: .ascii, allowLossyConversion: false)!
        let postLength = "\(postData.count)"
        urlRequest.setValue(postLength, forHTTPHeaderField: Keys.contentLength)
        urlRequest.httpBody = postData
        
        let dataTask = urlSession.dataTask(with: urlRequest) { data, response, error in
            let result = self.parseJSONResponse(
                operation: operation.description,
                data: data,
                error: error
            )
            switch result {
            case .success(let json):
                if let token = self.parseTokenResponse(json: json, refreshToken: refreshToken) {
                    Diag.debug("OAuth token acquired successfully [operation: \(operation)]")
                    completionQueue.addOperation {
                        completion(.success(token))
                    }
                } else {
                    completionQueue.addOperation {
                        completion(.failure(.misformattedResponse))
                    }
                }
            case .failure(let oneDriveError):
                completionQueue.addOperation {
                    completion(.failure(oneDriveError))
                }
            }
        }
        dataTask.resume()
    }
    
    private func parseTokenResponse(json: [String: Any], refreshToken: String?) -> OAuthToken? {
        guard let accessToken = json[Keys.accessToken] as? String else {
            Diag.error("Failed to parse token response: access_token missing")
            return nil
        }
        guard let expires_in = json[Keys.expiresIn] as? Int else {
            Diag.error("Failed to parse token response: expires_in missing")
            return nil
        }
        guard let refreshToken = (refreshToken ?? json[Keys.refreshToken] as? String) else {
            Diag.error("Failed to parse token response: refresh_token missing")
            return nil
        }
        
        let token = OAuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            acquired: Date.now,
            lifespan: TimeInterval(expires_in)
        )
        return token
    }
    
    private func maybeRefreshToken(
        token: OAuthToken,
        completionQueue: OperationQueue,
        completion: @escaping (Result<OAuthToken, OneDriveError>) -> Void
    ) -> Void {
        if Date.now < (token.acquired + token.halflife) {
            completionQueue.addOperation {
                completion(.success(token))
            }
        } else if token.refreshToken.isEmpty {
            completionQueue.addOperation {
                Diag.error("OAuth token expired and there is no refresh token")
                completion(.failure(.cannotRefreshToken))
            }
        } else {
            getToken(
                operation: .refresh(token: token),
                completionQueue: completionQueue,
                completion: completion
            )
        }
    }
}

extension OneDriveManager: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let sessionObjectID = ObjectIdentifier(session)
        return presentationAnchors[sessionObjectID]!.value!
    }
}

extension OneDriveManager {
    public func getDriveInfo(
        freshToken token: OAuthToken,
        completionQueue: OperationQueue = .main,
        completion: @escaping (Result<OneDriveDriveInfo, OneDriveError>) -> Void
    ) {
        Diag.debug("Requesting drive info")
        let driveInfoURL = URL(string: AuthConfig.apiEndPoint)!
        var urlRequest = URLRequest(url: driveInfoURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: Keys.authorization)
        
        let dataTask = urlSession.dataTask(with: urlRequest) { data, response, error in
            let result = self.parseJSONResponse(operation: "getDriveInfo", data: data, error: error)
            switch result {
            case .success(let json):
                if let driveInfo = self.parseDriveInfoResponse(json: json) {
                    Diag.debug("Drive info received successfully")
                    completionQueue.addOperation {
                        completion(.success(driveInfo))
                    }
                } else {
                    completionQueue.addOperation {
                        completion(.failure(.misformattedResponse))
                    }
                }
            case .failure(let oneDriveError):
                completionQueue.addOperation {
                    completion(.failure(oneDriveError))
                }
            }
        }
        dataTask.resume()
    }
    
    private func parseDriveInfoResponse(json: [String: Any]) -> OneDriveDriveInfo? {
        guard let driveID = json[Keys.id] as? String else {
            Diag.error("Failed to parse drive info: id field missing")
            return nil
        }
        guard let driveTypeString = json[Keys.driveType] as? String else {
            Diag.error("Failed to parse drive info: driveType field missing")
            return nil
        }
        guard let driveName = json[Keys.name] as? String else {
            Diag.error("Failed to parse drive info: name field missing")
            return nil
        }

        var ownerEmail: String?
        if let ownerDict = json[Keys.owner] as? [String: Any],
           let userDict = ownerDict[Keys.user] as? [String: Any],
           let ownerEmailString = userDict[Keys.email] as? String
        {
            ownerEmail = ownerEmailString
        }

        let result = OneDriveDriveInfo(
            id: driveID,
            name: driveName,
            type: .init(rawValue: driveTypeString) ?? .personal,
            ownerEmail: ownerEmail
        )
        return result
    }
}

extension OneDriveManager {
    
    public func getItems(
        in folder: String,
        token: OAuthToken,
        tokenUpdater: TokenUpdateCallback?,
        completionQueue: OperationQueue = .main,
        completion: @escaping (Result<[RemoteFileItem], OneDriveError>)->Void
    ) {
        Diag.debug("Acquiring file list")
        maybeRefreshToken(token: token, completionQueue: completionQueue) { authResult in
            switch authResult {
            case .success(let newToken):
                tokenUpdater?(newToken)
                self.getItems(
                    inFolder: folder,
                    freshToken: newToken,
                    completionQueue: completionQueue,
                    completion: completion
                )
            case .failure(let oneDriveError):
                completionQueue.addOperation {
                    completion(.failure(oneDriveError))
                }
                return
            }
        }
    }
    
    private func getItems(
        inFolder folderPath: String,
        freshToken token: OAuthToken,
        completionQueue: OperationQueue,
        completion: @escaping (Result<[RemoteFileItem], OneDriveError>)->Void
    ) {
        let urlString: String
        let fields = "id,name,size,createdDateTime,lastModifiedDateTime,folder,file"
        if folderPath == "/" {
            urlString = AuthConfig.apiEndPoint + "/root/children?select=\(fields)"
        } else {
            let encodedPath = folderPath
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            urlString = AuthConfig.apiEndPoint + "/root:\(encodedPath):/children?select=\(fields)"
        }
        let requestURL = URL(string: urlString)!
        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: Keys.authorization)
        
        let dataTask = urlSession.dataTask(with: urlRequest) { data, response, error in
            let result = self.parseJSONResponse(operation: "listFiles", data: data, error: error)
            switch result {
            case .success(let json):
                if let fileItems = self.parseFileListResponse(json, folderPath: folderPath) {
                    Diag.debug("File list acquired successfully")
                    completionQueue.addOperation {
                        completion(.success(fileItems))
                    }
                } else {
                    completionQueue.addOperation {
                        completion(.failure(.misformattedResponse))
                    }
                }
            case .failure(let oneDriveError):
                completionQueue.addOperation {
                    completion(.failure(oneDriveError))
                }
            }
        }
        dataTask.resume()
    }
    
    private func parseFileListResponse(_ json: [String: Any], folderPath: String) -> [RemoteFileItem]? {
        guard let items = json[Keys.value] as? [[String: Any]] else {
            Diag.error("Failed to parse file list response: value field missing")
            return nil
        }
        let folderPathWithTrailingSlash = folderPath.withTrailingSlash()
        let result = items.compactMap { infoDict -> RemoteFileItem? in
            guard let itemID = infoDict[Keys.id] as? String,
                  let itemName = infoDict[Keys.name] as? String
            else {
                Diag.debug("Failed to parse file item: id or name field missing; skipping the file")
                return nil
            }
            return RemoteFileItem(
                itemID: itemID,
                itemPath: folderPathWithTrailingSlash + itemName,
                isFolder: infoDict[Keys.folder] != nil,
                fileInfo: FileInfo(
                    fileName: itemName,
                    fileSize: infoDict[Keys.size] as? Int64,
                    creationDate: Date(
                        iso8601string: infoDict[Keys.createdDateTime] as? String),
                    modificationDate: Date(
                        iso8601string: infoDict[Keys.lastModifiedDateTime] as? String),
                    isExcludedFromBackup: nil,
                    isInTrash: false 
                )
            )
        }
        return result
    }
}

extension OneDriveManager {
    
    public func getItemInfo(
        path: String,
        token: OAuthToken,
        tokenUpdater: TokenUpdateCallback?,
        completionQueue: OperationQueue = .main,
        completion: @escaping (Result<RemoteFileItem, OneDriveError>)->Void
    ) {
        Diag.debug("Acquiring file list")
        maybeRefreshToken(token: token, completionQueue: completionQueue) { authResult in
            switch authResult {
            case .success(let newToken):
                tokenUpdater?(newToken)
                self.getItemInfo(
                    path: path,
                    freshToken: newToken,
                    completionQueue: completionQueue,
                    completion: completion
                )
            case .failure(let oneDriveError):
                completionQueue.addOperation {
                    completion(.failure(oneDriveError))
                }
                return
            }
        }
    }
    
    private func getItemInfo(
        path: String,
        freshToken token: OAuthToken,
        completionQueue: OperationQueue,
        completion: @escaping (Result<RemoteFileItem, OneDriveError>)->Void
    ) {
        let encodedPath = path
            .withLeadingSlash()
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let urlString = AuthConfig.apiEndPoint + "/root:\(encodedPath)"
        let fileInfoRequestURL = URL(string: urlString)!
        var urlRequest = URLRequest(url: fileInfoRequestURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: Keys.authorization)
        
        let dataTask = urlSession.dataTask(with: urlRequest) { data, response, error in
            let result = self.parseJSONResponse(operation: "itemInfo", data: data, error: error)
            switch result {
            case .success(let json):
                if let fileItems = self.parseItemInfoResponse(json, path: path) {
                    Diag.debug("File list acquired successfully")
                    completionQueue.addOperation {
                        completion(.success(fileItems))
                    }
                } else {
                    completionQueue.addOperation {
                        completion(.failure(.misformattedResponse))
                    }
                }
            case .failure(let oneDriveError):
                completionQueue.addOperation {
                    completion(.failure(oneDriveError))
                }
            }
        }
        dataTask.resume()
    }
    
    private func parseItemInfoResponse(_ json: [String: Any], path: String) -> RemoteFileItem? {
        guard let itemID = json[Keys.id] as? String,
              let itemName = json[Keys.name] as? String
        else {
            Diag.debug("Failed to parse item info: id or name field missing")
            return nil
        }
        return RemoteFileItem(
            itemID: itemID,
            itemPath: path,
            isFolder: json[Keys.folder] != nil,
            fileInfo: FileInfo(
                fileName: itemName,
                fileSize: json[Keys.size] as? Int64,
                creationDate: Date(iso8601string: json[Keys.createdDateTime] as? String),
                modificationDate: Date(iso8601string: json[Keys.lastModifiedDateTime] as? String),
                isExcludedFromBackup: nil,
                isInTrash: false 
            )
        )
    }
}

extension OneDriveManager {
    
    public func getFileContents(
        filePath: String,
        token: OAuthToken,
        tokenUpdater: TokenUpdateCallback?,
        completionQueue: OperationQueue = .main,
        completion: @escaping (Result<Data, OneDriveError>) -> Void
    ) {
        Diag.debug("Downloading file")
        maybeRefreshToken(token: token, completionQueue: completionQueue) { authResult in
            switch authResult {
            case .success(let newToken):
                tokenUpdater?(newToken)
                self.getFileContents(
                    filePath: filePath,
                    freshToken: newToken,
                    completionQueue: completionQueue,
                    completion: completion
                )
            case .failure(let oneDriveError):
                completionQueue.addOperation {
                    completion(.failure(oneDriveError))
                }
                return
            }
        }
    }
    
    private func getFileContents(
        filePath: String,
        freshToken token: OAuthToken,
        completionQueue: OperationQueue,
        completion: @escaping (Result<Data, OneDriveError>) -> Void
    ) {
        let encodedPath = filePath
            .withLeadingSlash()
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let urlString = AuthConfig.apiEndPoint + "/root:\(encodedPath):/content"
        let fileContentsURL = URL(string: urlString)!
        var urlRequest = URLRequest(url: fileContentsURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: Keys.authorization)
        
        let dataTask = urlSession.dataTask(with: urlRequest) { data, response, error in
            if let error = error {
                completionQueue.addOperation {
                    Diag.error("Failed to download file [message: \(error.localizedDescription)]")
                    completion(.failure(.general(error: error)))
                }
                return
            }
            guard let data = data else {
                completionQueue.addOperation {
                    Diag.error("Failed to download file: no data returned")
                    completion(.failure(.emptyResponse))
                }
                return
            }
            if response?.mimeType == "application/json",
               let json = self.parseJSONDict(data: data),
               let serverErrorMessage = self.getServerErrorMessage(from: json)
            {
                completionQueue.addOperation {
                    Diag.error("Failed to download file, server returned error [message: \(serverErrorMessage)]")
                    completion(.failure(.serverSideError(message: serverErrorMessage)))
                }
                return
            }

            completionQueue.addOperation {
                Diag.debug("File downloaded successfully [size: \(data.count)]")
                completion(.success(data))
            }
        }
        dataTask.resume()
    }
}

extension OneDriveManager {
    public typealias UploadCompletionHandler = (Result<String, OneDriveError>) -> Void
    
    public func uploadFile(
        filePath: String,
        contents: ByteArray,
        fileName: String,
        token: OAuthToken,
        tokenUpdater: TokenUpdateCallback?,
        completionQueue: OperationQueue = .main,
        completion: @escaping UploadCompletionHandler
    ) {
        Diag.debug("Uploading file")
        
        guard contents.count < maxUploadSize else {
            Diag.error("Such a large upload is not supported. Please contact support. [fileSize: \(contents.count)]")
            completionQueue.addOperation {
                completion(.failure(.serverSideError(message: "Upload is too large")))
            }
            return
        }
        
        maybeRefreshToken(token: token, completionQueue: completionQueue) { authResult in
            switch authResult {
            case .success(let newToken):
                tokenUpdater?(newToken)
                self.uploadFile(
                    filePath: filePath,
                    contents: contents,
                    fileName: fileName,
                    freshToken: newToken,
                    completionQueue: completionQueue,
                    completion: completion
                )
            case .failure(let oneDriveError):
                completionQueue.addOperation {
                    completion(.failure(oneDriveError))
                }
                return
            }
        }
    }
    
    private func uploadFile(
        filePath: String,
        contents: ByteArray,
        fileName: String,
        freshToken token: OAuthToken,
        completionQueue: OperationQueue,
        completion: @escaping UploadCompletionHandler
    ) {
        
        Diag.debug("Creating upload session")
        let encodedPath = filePath
            .withLeadingSlash()
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let urlString = AuthConfig.apiEndPoint + "/root:\(encodedPath):/createUploadSession"
        let createSessionURL = URL(string: urlString)!
        var urlRequest = URLRequest(url: createSessionURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: Keys.authorization)
        urlRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: Keys.contentType)
        let postData = try! JSONSerialization.data(withJSONObject: [
            "@microsoft.graph.conflictBehavior": "rename"
        ])
        urlRequest.httpBody = postData
        urlRequest.setValue(String(postData.count), forHTTPHeaderField: Keys.contentLength)
        

        let dataTask = urlSession.dataTask(with: urlRequest) { data, response, error in
            let result = self.parseJSONResponse(operation: "uploadSession", data: data, error: error)
            switch result {
            case .success(let json):
                if let uploadURL = self.parseCreateUploadSessionResponse(json) {
                    Diag.debug("Upload session created successfully")
                    self.uploadData(
                        contents,
                        toURL: uploadURL,
                        completionQueue: completionQueue,
                        completion: completion
                    )
                } else {
                    completionQueue.addOperation {
                        completion(.failure(.misformattedResponse))
                    }
                }
            case .failure(let oneDriveError):
                completionQueue.addOperation {
                    completion(.failure(oneDriveError))
                }
            }
        }
        dataTask.resume()
    }
    
    private func parseCreateUploadSessionResponse(_ json: [String: Any]) -> URL? {
        guard let uploadURLString = json[Keys.uploadUrl] as? String else {
            Diag.debug("Failed to parse upload session response: uploadUrl field missing")
            return nil
        }
        guard let uploadURL = URL(string: uploadURLString) else {
            Diag.debug("Failed to parse upload session URL")
            return nil
        }
        return uploadURL
    }
    
    private func uploadData(
        _ data: ByteArray,
        toURL targetURL: URL,
        completionQueue: OperationQueue,
        completion: @escaping UploadCompletionHandler
    ) {
        Diag.debug("Uploading file contents")
        assert(data.count < maxUploadSize, "Upload request is too large; range uploads are not implemented")

        var urlRequest = URLRequest(url: targetURL)
        urlRequest.httpMethod = "PUT"
        
        let fileSize = data.count 
        let range = 0..<data.count
        urlRequest.setValue(
            String(range.count),
            forHTTPHeaderField: Keys.contentLength) 
        urlRequest.setValue(
            "bytes \(range.first!)-\(range.last!)/\(fileSize)",
            forHTTPHeaderField: Keys.contentRange) 
        urlRequest.httpBody = data.asData[range]

        let dataTask = urlSession.dataTask(with: urlRequest) { data, response, error in
            let result = self.parseJSONResponse(operation: "uploadData", data: data, error: error)
            switch result {
            case .success(let json):
                if let finalName = self.parseUploadDataResponse(json) {
                    Diag.debug("File contents uploaded successfully")
                    completionQueue.addOperation {
                        completion(.success(finalName))
                    }
                } else {
                    completionQueue.addOperation {
                        completion(.failure(.misformattedResponse))
                    }
                }
            case .failure(let oneDriveError):
                completionQueue.addOperation {
                    completion(.failure(oneDriveError))
                }
            }
        }
        dataTask.resume()
    }
    
    private func parseUploadDataResponse(_ json: [String: Any]) -> String? {
        Diag.debug("Upload successful [response: \(json.description)]")
        guard let fileName = json[Keys.name] as? String else {
            Diag.debug("Failed to parse upload response: name field missing")
            return nil
        }
        return fileName
    }
}
