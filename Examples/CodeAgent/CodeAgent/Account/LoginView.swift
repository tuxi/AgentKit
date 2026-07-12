//
//  LoginView.swift
//  AgentKit
//
//  登录页面。支持密码登录和 Apple 登录。
//

import SwiftUI
import AgentKit

#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

// MARK: - LoginView

public struct LoginView: View {
    @Environment(AccountManager.self) private var accountManager
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showRegister = false

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Title
            VStack(spacing: 8) {
                Text("Sign in to CodeAgent")
                    .font(.title2.bold())
                Text("Access Agent Gateway and sync across devices")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Email/Password
            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .textFieldStyle(.roundedBorder)

            // Error
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Sign In
            Button {
                Task { await performLogin() }
            } label: {
                if isLoading {
                    ProgressView()
                } else {
                    Text("Sign In")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || email.isEmpty || password.isEmpty)

            // Apple Sign In
            #if canImport(AuthenticationServices)
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email, .fullName]
            } onCompletion: { result in
                Task { await handleAppleLogin(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 44)
            #endif

            // Register
            Button("Create Account") {
                showRegister = true
            }
            .disabled(isLoading)

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showRegister) {
            RegisterView()
        }
    }

    private func performLogin() async {
        isLoading = true
        errorMessage = nil
        do {
            try await accountManager.login(email: email, password: password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func handleAppleLogin(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken,
                  let identityTokenString = String(data: identityToken, encoding: .utf8),
                  let authCode = credential.authorizationCode,
                  let authCodeString = String(data: authCode, encoding: .utf8)
            else {
                errorMessage = "Apple 登录失败：无法获取授权信息。"
                return
            }
            isLoading = true
            errorMessage = nil
            do {
                try await accountManager.loginWithApple(
                    identityToken: identityTokenString,
                    authorizationCode: authCodeString,
                    email: credential.email,
                    givenName: credential.fullName?.givenName,
                    familyName: credential.fullName?.familyName
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - RegisterView

struct RegisterView: View {
    @Environment(AccountManager.self) private var accountManager
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Email") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                }
                Section("Password") {
                    SecureField("Password", text: $password)
                }
                Section("Display Name (optional)") {
                    TextField("Name", text: $displayName)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Create Account") {
                        Task { await performRegister() }
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Create Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func performRegister() async {
        isLoading = true
        errorMessage = nil
        do {
            try await accountManager.login(email: email, password: password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
