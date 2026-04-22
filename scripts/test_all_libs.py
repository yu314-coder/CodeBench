"""Comprehensive test of ALL OfflinAi Python libraries.
Run in the Editor tab with Python selected."""

import sys, time
_t0 = time.time()
_pass = 0
_fail = 0
_errors = []

def t(name, fn):
    global _pass, _fail
    try:
        fn()
        _pass += 1
        print(f"  ✓ {name}")
    except Exception as e:
        _fail += 1
        _errors.append((name, str(e)[:120]))
        print(f"  ✗ {name}: {e}")

def section(title):
    print(f"\n{'='*50}")
    print(f"  {title}")
    print(f"{'='*50}")

# ════════════════════════════════════════════════════
section("NUMPY")
# ════════════════════════════════════════════════════
import numpy as np
t("array creation", lambda: np.array([1,2,3]))
t("linspace", lambda: np.linspace(0, 1, 100))
t("zeros/ones/eye", lambda: (np.zeros((3,3)), np.ones(5), np.eye(4)))
t("random", lambda: np.random.randn(10, 5))
t("linalg.solve", lambda: np.linalg.solve([[3,1],[1,2]], [9,8]))
t("linalg.eig", lambda: np.linalg.eig(np.random.randn(3,3)))
t("linalg.svd", lambda: np.linalg.svd(np.random.randn(4,3)))
t("fft", lambda: np.fft.fft(np.sin(np.linspace(0, 2*np.pi, 64))))
t("meshgrid", lambda: np.meshgrid(np.arange(5), np.arange(5)))
t("broadcasting", lambda: np.arange(10).reshape(2,5) + np.arange(5))
t("boolean indexing", lambda: np.arange(10)[np.arange(10) > 5])
t("matmul", lambda: np.matmul(np.random.randn(3,4), np.random.randn(4,5)))

# ════════════════════════════════════════════════════
section("SCIPY")
# ════════════════════════════════════════════════════
t("scipy.optimize.minimize", lambda: __import__('scipy.optimize', fromlist=['minimize']).minimize(lambda x: x[0]**2+x[1]**2, [1,1], method='Nelder-Mead'))
t("scipy.integrate.quad", lambda: __import__('scipy.integrate', fromlist=['quad']).quad(lambda x: x**2, 0, 1))
t("scipy.stats.norm", lambda: __import__('scipy.stats', fromlist=['norm']).norm.pdf(0))
t("scipy.interpolate.interp1d", lambda: __import__('scipy.interpolate', fromlist=['interp1d']).interp1d([0,1,2],[0,1,4])([0.5, 1.5]))
t("scipy.linalg.solve", lambda: __import__('scipy.linalg', fromlist=['solve']).solve([[1,2],[3,4]], [5,6]))
t("scipy.fft.rfft", lambda: __import__('scipy.fft', fromlist=['rfft']).rfft(np.sin(np.linspace(0, 2*np.pi, 64))))
t("scipy.signal.butter", lambda: __import__('scipy.signal', fromlist=['butter']).butter(4, 0.1))
t("scipy.spatial.distance", lambda: __import__('scipy.spatial.distance', fromlist=['euclidean']).euclidean([0,0],[3,4]))
t("scipy.sparse.csr_matrix", lambda: __import__('scipy.sparse', fromlist=['csr_matrix']).csr_matrix(np.eye(3)))
t("scipy.special.gamma", lambda: __import__('scipy.special', fromlist=['gamma']).gamma(5))
t("scipy.ndimage.gaussian_filter", lambda: __import__('scipy.ndimage', fromlist=['gaussian_filter']).gaussian_filter(np.random.randn(10,10), sigma=1))
t("scipy.cluster.hierarchy.linkage", lambda: __import__('scipy.cluster.hierarchy', fromlist=['linkage']).linkage(np.random.randn(10,3)))
t("scipy.constants.pi", lambda: __import__('scipy.constants', fromlist=['pi']).pi)

# ════════════════════════════════════════════════════
section("SKLEARN - Datasets")
# ════════════════════════════════════════════════════
from sklearn.datasets import (make_classification, make_regression, make_blobs,
    make_moons, make_circles, load_iris, load_digits, load_wine,
    load_breast_cancer, load_diabetes, make_swiss_roll, make_s_curve,
    make_friedman1, make_friedman2, make_friedman3)

t("make_classification", lambda: make_classification(100, 10, random_state=0))
t("make_regression", lambda: make_regression(100, 5, random_state=0))
t("make_blobs", lambda: make_blobs(100, random_state=0))
t("make_moons", lambda: make_moons(100, random_state=0))
t("make_circles", lambda: make_circles(100, random_state=0))
t("load_iris", lambda: load_iris())
t("load_digits", lambda: load_digits())
t("load_wine", lambda: load_wine())
t("load_breast_cancer", lambda: load_breast_cancer())
t("load_diabetes", lambda: load_diabetes())
t("make_swiss_roll", lambda: make_swiss_roll(100, random_state=0))
t("make_s_curve", lambda: make_s_curve(100, random_state=0))
t("make_friedman1", lambda: make_friedman1(100, random_state=0))
t("make_friedman2", lambda: make_friedman2(100, random_state=0))
t("make_friedman3", lambda: make_friedman3(100, random_state=0))

# ════════════════════════════════════════════════════
section("SKLEARN - Model Selection")
# ════════════════════════════════════════════════════
from sklearn.model_selection import (train_test_split, cross_val_score,
    KFold, StratifiedKFold, LeaveOneOut, TimeSeriesSplit, GridSearchCV,
    RandomizedSearchCV, cross_validate, learning_curve, validation_curve,
    ShuffleSplit, RepeatedKFold, GroupKFold)
from sklearn.linear_model import LinearRegression, Ridge

X, y = make_classification(200, 10, random_state=42)
Xr, yr = make_regression(200, 5, random_state=42)

t("train_test_split", lambda: train_test_split(X, y, test_size=0.3))
t("KFold.split", lambda: list(KFold(5).split(X)))
t("StratifiedKFold.split", lambda: list(StratifiedKFold(5).split(X, y)))
t("LeaveOneOut.split(10)", lambda: list(LeaveOneOut().split(np.arange(10).reshape(-1,1))))
t("TimeSeriesSplit.split", lambda: list(TimeSeriesSplit(3).split(X)))
t("ShuffleSplit.split", lambda: list(ShuffleSplit(3, random_state=0).split(X)))
t("RepeatedKFold.split", lambda: list(RepeatedKFold(n_splits=3, n_repeats=2, random_state=0).split(X)))
t("cross_val_score", lambda: cross_val_score(Ridge(), Xr, yr, cv=3))
t("cross_validate", lambda: cross_validate(Ridge(), Xr, yr, cv=3))

# ════════════════════════════════════════════════════
section("SKLEARN - Preprocessing")
# ════════════════════════════════════════════════════
from sklearn.preprocessing import (StandardScaler, MinMaxScaler, RobustScaler,
    MaxAbsScaler, Normalizer, Binarizer, LabelEncoder, OneHotEncoder,
    OrdinalEncoder, LabelBinarizer, PolynomialFeatures, PowerTransformer,
    QuantileTransformer, KBinsDiscretizer, FunctionTransformer, SplineTransformer,
    TargetEncoder)

Xp = np.random.randn(50, 4)
t("StandardScaler", lambda: StandardScaler().fit_transform(Xp))
t("MinMaxScaler", lambda: MinMaxScaler().fit_transform(Xp))
t("RobustScaler", lambda: RobustScaler().fit_transform(Xp))
t("MaxAbsScaler", lambda: MaxAbsScaler().fit_transform(Xp))
t("Normalizer", lambda: Normalizer().fit_transform(Xp))
t("Binarizer", lambda: Binarizer(threshold=0.0).fit_transform(Xp))
t("LabelEncoder", lambda: LabelEncoder().fit_transform(['cat','dog','cat','bird']))
t("OneHotEncoder", lambda: OneHotEncoder(sparse_output=False).fit_transform(np.array([[0],[1],[2],[0]])))
t("OrdinalEncoder", lambda: OrdinalEncoder().fit_transform(np.array([['a'],['b'],['c'],['a']])))
t("LabelBinarizer", lambda: LabelBinarizer().fit_transform([0,1,2,0,1]))
t("PolynomialFeatures", lambda: PolynomialFeatures(2).fit_transform(Xp[:5,:2]))
t("PowerTransformer", lambda: PowerTransformer().fit_transform(np.abs(Xp)+1))
t("QuantileTransformer", lambda: QuantileTransformer(n_quantiles=20).fit_transform(Xp))
t("KBinsDiscretizer", lambda: KBinsDiscretizer(n_bins=3, encode='ordinal', strategy='uniform').fit_transform(Xp))
t("FunctionTransformer", lambda: FunctionTransformer(func=np.log1p).fit_transform(np.abs(Xp)))
t("SplineTransformer", lambda: SplineTransformer(n_knots=4, degree=3).fit_transform(Xp[:, :1]))

# ════════════════════════════════════════════════════
section("SKLEARN - Linear Models")
# ════════════════════════════════════════════════════
from sklearn.linear_model import (LogisticRegression, Lasso, ElasticNet,
    SGDClassifier, SGDRegressor, RidgeClassifier, Perceptron,
    BayesianRidge, HuberRegressor, Lars, LassoLars, PoissonRegressor)

Xt, Xte, yt, yte = train_test_split(X, y, test_size=0.3, random_state=0)
Xrt, Xrte, yrt, yrte = train_test_split(Xr, yr, test_size=0.3, random_state=0)

t("LinearRegression", lambda: LinearRegression().fit(Xrt, yrt).predict(Xrte))
t("Ridge", lambda: Ridge().fit(Xrt, yrt).predict(Xrte))
t("Lasso", lambda: Lasso(alpha=0.1).fit(Xrt, yrt).predict(Xrte))
t("ElasticNet", lambda: ElasticNet(alpha=0.1).fit(Xrt, yrt).predict(Xrte))
t("LogisticRegression", lambda: LogisticRegression().fit(Xt, yt).predict(Xte))
t("SGDClassifier", lambda: SGDClassifier(random_state=0).fit(Xt, yt).predict(Xte))
t("SGDRegressor", lambda: SGDRegressor(random_state=0).fit(Xrt, yrt).predict(Xrte))
t("RidgeClassifier", lambda: RidgeClassifier().fit(Xt, yt).predict(Xte))
t("Perceptron", lambda: Perceptron(random_state=0).fit(Xt, yt).predict(Xte))
t("BayesianRidge", lambda: BayesianRidge().fit(Xrt, yrt).predict(Xrte))
t("HuberRegressor", lambda: HuberRegressor().fit(Xrt, yrt).predict(Xrte))
t("Lars", lambda: Lars().fit(Xrt, yrt).predict(Xrte))
t("LassoLars", lambda: LassoLars(alpha=0.01).fit(Xrt, yrt).predict(Xrte))
t("PoissonRegressor", lambda: PoissonRegressor().fit(np.abs(Xrt)+1, np.abs(yrt)+1).predict(np.abs(Xrte)+1))

# ════════════════════════════════════════════════════
section("SKLEARN - Ensemble")
# ════════════════════════════════════════════════════
from sklearn.ensemble import (RandomForestClassifier, RandomForestRegressor,
    GradientBoostingClassifier, GradientBoostingRegressor,
    AdaBoostClassifier, AdaBoostRegressor, BaggingClassifier, BaggingRegressor,
    ExtraTreesClassifier, ExtraTreesRegressor,
    HistGradientBoostingClassifier, HistGradientBoostingRegressor,
    IsolationForest, VotingClassifier, VotingRegressor,
    StackingClassifier, StackingRegressor)

t("RandomForestClassifier", lambda: RandomForestClassifier(n_estimators=10, random_state=0).fit(Xt, yt).predict(Xte))
t("RandomForestRegressor", lambda: RandomForestRegressor(n_estimators=10, random_state=0).fit(Xrt, yrt).predict(Xrte))
t("GradientBoostingClassifier", lambda: GradientBoostingClassifier(n_estimators=20, random_state=0).fit(Xt, yt).predict(Xte))
t("GradientBoostingRegressor", lambda: GradientBoostingRegressor(n_estimators=20).fit(Xrt, yrt).predict(Xrte))
t("AdaBoostClassifier", lambda: AdaBoostClassifier(n_estimators=20, random_state=0).fit(Xt, yt).predict(Xte))
t("AdaBoostRegressor", lambda: AdaBoostRegressor(n_estimators=20, random_state=0).fit(Xrt, yrt).predict(Xrte))
t("BaggingClassifier", lambda: BaggingClassifier(n_estimators=10, random_state=0).fit(Xt, yt).predict(Xte))
t("BaggingRegressor", lambda: BaggingRegressor(n_estimators=10, random_state=0).fit(Xrt, yrt).predict(Xrte))
t("ExtraTreesClassifier", lambda: ExtraTreesClassifier(n_estimators=10, random_state=0).fit(Xt, yt).predict(Xte))
t("ExtraTreesRegressor", lambda: ExtraTreesRegressor(n_estimators=10, random_state=0).fit(Xrt, yrt).predict(Xrte))
t("HistGradientBoostingClassifier", lambda: HistGradientBoostingClassifier(max_iter=20, random_state=0).fit(Xt, yt).predict(Xte))
t("HistGradientBoostingRegressor", lambda: HistGradientBoostingRegressor(max_iter=20).fit(Xrt, yrt).predict(Xrte))
t("IsolationForest", lambda: IsolationForest(n_estimators=20, random_state=0).fit(Xt).predict(Xte))
t("VotingClassifier", lambda: VotingClassifier(estimators=[('lr', LogisticRegression()), ('rf', RandomForestClassifier(n_estimators=5, random_state=0))]).fit(Xt, yt).predict(Xte))
t("VotingRegressor", lambda: VotingRegressor(estimators=[('lr', LinearRegression()), ('r', Ridge())]).fit(Xrt, yrt).predict(Xrte))
t("StackingClassifier", lambda: StackingClassifier(estimators=[('lr', LogisticRegression())], cv=2).fit(Xt, yt).predict(Xte))
t("StackingRegressor", lambda: StackingRegressor(estimators=[('lr', LinearRegression())], cv=2).fit(Xrt, yrt).predict(Xrte))

# ════════════════════════════════════════════════════
section("SKLEARN - Tree, SVM, Neighbors, NaiveBayes")
# ════════════════════════════════════════════════════
from sklearn.tree import DecisionTreeClassifier, DecisionTreeRegressor, ExtraTreeClassifier, ExtraTreeRegressor
from sklearn.svm import SVC, SVR, LinearSVC, LinearSVR, NuSVC, NuSVR, OneClassSVM
from sklearn.neighbors import (KNeighborsClassifier, KNeighborsRegressor,
    NearestNeighbors, NearestCentroid, LocalOutlierFactor, KernelDensity,
    RadiusNeighborsClassifier, RadiusNeighborsRegressor)
from sklearn.naive_bayes import GaussianNB, MultinomialNB, BernoulliNB

t("DecisionTreeClassifier", lambda: DecisionTreeClassifier().fit(Xt, yt).predict(Xte))
t("DecisionTreeRegressor", lambda: DecisionTreeRegressor().fit(Xrt, yrt).predict(Xrte))
t("ExtraTreeClassifier", lambda: ExtraTreeClassifier(random_state=0).fit(Xt, yt).predict(Xte))
t("ExtraTreeRegressor", lambda: ExtraTreeRegressor(random_state=0).fit(Xrt, yrt).predict(Xrte))
t("SVC", lambda: SVC().fit(Xt, yt).predict(Xte))
t("SVR", lambda: SVR().fit(Xrt, yrt).predict(Xrte))
t("LinearSVC", lambda: LinearSVC(random_state=0).fit(Xt, yt).predict(Xte))
t("LinearSVR", lambda: LinearSVR(random_state=0).fit(Xrt, yrt).predict(Xrte))
t("NuSVC", lambda: NuSVC().fit(Xt, yt).predict(Xte))
t("NuSVR", lambda: NuSVR().fit(Xrt, yrt).predict(Xrte))
t("OneClassSVM", lambda: OneClassSVM().fit(Xt).predict(Xte))
t("KNeighborsClassifier", lambda: KNeighborsClassifier().fit(Xt, yt).predict(Xte))
t("KNeighborsRegressor", lambda: KNeighborsRegressor().fit(Xrt, yrt).predict(Xrte))
t("NearestNeighbors", lambda: NearestNeighbors().fit(Xt).kneighbors(Xte[:5]))
t("NearestCentroid", lambda: NearestCentroid().fit(Xt, yt).predict(Xte))
t("LocalOutlierFactor", lambda: LocalOutlierFactor().fit_predict(Xt))
t("KernelDensity", lambda: KernelDensity().fit(Xt).score_samples(Xte[:5]))
t("GaussianNB", lambda: GaussianNB().fit(Xt, yt).predict(Xte))
t("MultinomialNB", lambda: MultinomialNB().fit(np.abs(Xt), yt).predict(np.abs(Xte)))
t("BernoulliNB", lambda: BernoulliNB().fit(Xt > 0, yt).predict(Xte > 0))

# ════════════════════════════════════════════════════
section("SKLEARN - Cluster")
# ════════════════════════════════════════════════════
from sklearn.cluster import (KMeans, MiniBatchKMeans, DBSCAN,
    AgglomerativeClustering, SpectralClustering, MeanShift, OPTICS,
    Birch, AffinityPropagation, BisectingKMeans, HDBSCAN, FeatureAgglomeration)

Xc, _ = make_blobs(100, centers=3, random_state=0)
t("KMeans", lambda: KMeans(3, random_state=0, n_init=3).fit_predict(Xc))
t("MiniBatchKMeans", lambda: MiniBatchKMeans(3, random_state=0, n_init=3).fit_predict(Xc))
t("DBSCAN", lambda: DBSCAN(eps=1.0).fit_predict(Xc))
t("AgglomerativeClustering", lambda: AgglomerativeClustering(3).fit_predict(Xc))
t("SpectralClustering", lambda: SpectralClustering(3, random_state=0, n_init=3).fit_predict(Xc))
t("MeanShift", lambda: MeanShift().fit_predict(Xc))
t("OPTICS", lambda: OPTICS(min_samples=5).fit_predict(Xc))
t("Birch", lambda: Birch(n_clusters=3).fit_predict(Xc))
t("AffinityPropagation", lambda: AffinityPropagation(random_state=0).fit_predict(Xc))
t("BisectingKMeans", lambda: BisectingKMeans(3, random_state=0).fit_predict(Xc))
t("HDBSCAN", lambda: HDBSCAN(min_cluster_size=10).fit_predict(Xc))
t("FeatureAgglomeration", lambda: FeatureAgglomeration(n_clusters=2).fit_transform(Xc))

# ════════════════════════════════════════════════════
section("SKLEARN - Decomposition")
# ════════════════════════════════════════════════════
from sklearn.decomposition import (PCA, TruncatedSVD, NMF, FastICA,
    KernelPCA, IncrementalPCA, LatentDirichletAllocation, SparsePCA,
    FactorAnalysis, DictionaryLearning, MiniBatchNMF)

Xd = np.abs(np.random.randn(50, 8)) + 0.1
t("PCA", lambda: PCA(2).fit_transform(Xd))
t("TruncatedSVD", lambda: TruncatedSVD(2).fit_transform(Xd))
t("NMF", lambda: NMF(2, max_iter=50, random_state=0).fit_transform(Xd))
t("FastICA", lambda: FastICA(2, random_state=0).fit_transform(Xd))
t("KernelPCA", lambda: KernelPCA(2, kernel='rbf').fit_transform(Xd))
t("IncrementalPCA", lambda: IncrementalPCA(2).fit_transform(Xd))
t("LatentDirichletAllocation", lambda: LatentDirichletAllocation(2, max_iter=5, random_state=0).fit_transform(Xd))
t("SparsePCA", lambda: SparsePCA(2, max_iter=10, random_state=0).fit_transform(Xd))
t("FactorAnalysis", lambda: FactorAnalysis(2, max_iter=50).fit_transform(Xd))
t("DictionaryLearning", lambda: DictionaryLearning(2, max_iter=10, random_state=0).fit_transform(Xd))
t("MiniBatchNMF", lambda: MiniBatchNMF(2, max_iter=50, random_state=0).fit_transform(Xd))

# ════════════════════════════════════════════════════
section("SKLEARN - Manifold, NeuralNet, GP, DA, Mixture")
# ════════════════════════════════════════════════════
from sklearn.manifold import TSNE, MDS, Isomap, LocallyLinearEmbedding, SpectralEmbedding
from sklearn.neural_network import MLPClassifier, MLPRegressor
from sklearn.gaussian_process import GaussianProcessClassifier, GaussianProcessRegressor
from sklearn.discriminant_analysis import LinearDiscriminantAnalysis, QuadraticDiscriminantAnalysis
from sklearn.mixture import GaussianMixture, BayesianGaussianMixture

Xs = Xt[:60]
ys = yt[:60]
t("TSNE", lambda: TSNE(2, random_state=0, perplexity=15).fit_transform(Xs))
t("MDS", lambda: MDS(2, random_state=0, max_iter=50).fit_transform(Xs))
t("Isomap", lambda: Isomap(n_components=2, n_neighbors=10).fit_transform(Xs))
t("LocallyLinearEmbedding", lambda: LocallyLinearEmbedding(n_components=2, n_neighbors=10).fit_transform(Xs))
t("SpectralEmbedding", lambda: SpectralEmbedding(n_components=2, n_neighbors=10).fit_transform(Xs))
t("MLPClassifier", lambda: MLPClassifier(hidden_layer_sizes=(20,), max_iter=50, random_state=0).fit(Xt, yt).predict(Xte))
t("MLPRegressor", lambda: MLPRegressor(hidden_layer_sizes=(20,), max_iter=50, random_state=0).fit(Xrt, yrt).predict(Xrte))
t("GaussianProcessClassifier", lambda: GaussianProcessClassifier(random_state=0).fit(Xs, ys).predict(Xs[:10]))
t("GaussianProcessRegressor", lambda: GaussianProcessRegressor(random_state=0).fit(Xrt[:30], yrt[:30]).predict(Xrte[:10]))
t("LinearDiscriminantAnalysis", lambda: LinearDiscriminantAnalysis().fit(Xt, yt).predict(Xte))
t("QuadraticDiscriminantAnalysis", lambda: QuadraticDiscriminantAnalysis().fit(Xt, yt).predict(Xte))
t("GaussianMixture", lambda: GaussianMixture(3, random_state=0).fit(Xc).predict(Xc))
t("BayesianGaussianMixture", lambda: BayesianGaussianMixture(3, random_state=0).fit(Xc).predict(Xc))

# ════════════════════════════════════════════════════
section("SKLEARN - Metrics")
# ════════════════════════════════════════════════════
from sklearn.metrics import (accuracy_score, confusion_matrix, classification_report,
    r2_score, roc_auc_score, log_loss, roc_curve, precision_recall_curve,
    f1_score, precision_score, recall_score, balanced_accuracy_score,
    matthews_corrcoef, cohen_kappa_score, silhouette_score,
    calinski_harabasz_score, davies_bouldin_score, pairwise_distances,
    adjusted_rand_score, mean_squared_error, mean_absolute_error,
    hamming_loss, jaccard_score, max_error, median_absolute_error,
    mean_absolute_percentage_error, explained_variance_score, brier_score_loss)

y_true_c = np.array([0,0,1,1,0,1,1,0,1,0])
y_pred_c = np.array([0,1,1,1,0,0,1,0,1,0])
y_prob = np.array([0.1,0.6,0.8,0.9,0.2,0.4,0.7,0.3,0.85,0.15])
y_true_r = np.array([1.0,2.0,3.0,4.0,5.0])
y_pred_r = np.array([1.1,2.2,2.8,4.1,4.9])

t("accuracy_score", lambda: accuracy_score(y_true_c, y_pred_c))
t("confusion_matrix", lambda: confusion_matrix(y_true_c, y_pred_c))
t("classification_report", lambda: classification_report(y_true_c, y_pred_c))
t("f1_score", lambda: f1_score(y_true_c, y_pred_c))
t("precision_score", lambda: precision_score(y_true_c, y_pred_c))
t("recall_score", lambda: recall_score(y_true_c, y_pred_c))
t("balanced_accuracy_score", lambda: balanced_accuracy_score(y_true_c, y_pred_c))
t("roc_auc_score", lambda: roc_auc_score(y_true_c, y_prob))
t("log_loss", lambda: log_loss(y_true_c, y_prob))
t("roc_curve", lambda: roc_curve(y_true_c, y_prob))
t("precision_recall_curve", lambda: precision_recall_curve(y_true_c, y_prob))
t("matthews_corrcoef", lambda: matthews_corrcoef(y_true_c, y_pred_c))
t("cohen_kappa_score", lambda: cohen_kappa_score(y_true_c, y_pred_c))
t("hamming_loss", lambda: hamming_loss(y_true_c, y_pred_c))
t("jaccard_score", lambda: jaccard_score(y_true_c, y_pred_c))
t("brier_score_loss", lambda: brier_score_loss(y_true_c, y_prob))
t("r2_score", lambda: r2_score(y_true_r, y_pred_r))
t("mean_squared_error", lambda: mean_squared_error(y_true_r, y_pred_r))
t("mean_absolute_error", lambda: mean_absolute_error(y_true_r, y_pred_r))
t("max_error", lambda: max_error(y_true_r, y_pred_r))
t("median_absolute_error", lambda: median_absolute_error(y_true_r, y_pred_r))
t("mean_absolute_percentage_error", lambda: mean_absolute_percentage_error(y_true_r, y_pred_r))
t("explained_variance_score", lambda: explained_variance_score(y_true_r, y_pred_r))
t("pairwise_distances", lambda: pairwise_distances(Xc[:10]))
t("silhouette_score", lambda: silhouette_score(Xc, KMeans(3, random_state=0, n_init=3).fit_predict(Xc)))
t("calinski_harabasz_score", lambda: calinski_harabasz_score(Xc, KMeans(3, random_state=0, n_init=3).fit_predict(Xc)))
t("davies_bouldin_score", lambda: davies_bouldin_score(Xc, KMeans(3, random_state=0, n_init=3).fit_predict(Xc)))
t("adjusted_rand_score", lambda: adjusted_rand_score([0,0,1,1,2,2], [0,0,1,1,1,2]))

# ════════════════════════════════════════════════════
section("SKLEARN - Pipeline, Compose, Impute, Inspection")
# ════════════════════════════════════════════════════
from sklearn.pipeline import Pipeline, make_pipeline
from sklearn.compose import ColumnTransformer
from sklearn.impute import SimpleImputer, KNNImputer
from sklearn.inspection import permutation_importance
from sklearn.feature_extraction import CountVectorizer, TfidfVectorizer
from sklearn.feature_selection import SelectKBest, VarianceThreshold

t("Pipeline", lambda: Pipeline([('scaler', StandardScaler()), ('lr', LogisticRegression())]).fit(Xt, yt).predict(Xte))
t("make_pipeline", lambda: make_pipeline(StandardScaler(), Ridge()).fit(Xrt, yrt).predict(Xrte))
t("SimpleImputer", lambda: SimpleImputer().fit_transform(np.array([[1,np.nan],[3,4],[np.nan,6]])))
t("KNNImputer", lambda: KNNImputer().fit_transform(np.array([[1,np.nan],[3,4],[np.nan,6],[2,3]])))
t("SelectKBest", lambda: SelectKBest(k=3).fit_transform(Xt, yt))
t("VarianceThreshold", lambda: VarianceThreshold().fit_transform(Xp))
t("CountVectorizer", lambda: CountVectorizer().fit_transform(["hello world", "world peace"]))
t("TfidfVectorizer", lambda: TfidfVectorizer().fit_transform(["hello world", "world peace"]))
t("permutation_importance", lambda: permutation_importance(Ridge().fit(Xrt, yrt), Xrte, yrte, n_repeats=3, random_state=0))

# ════════════════════════════════════════════════════
section("MATPLOTLIB")
# ════════════════════════════════════════════════════
import matplotlib
import matplotlib.pyplot as plt
import matplotlib.cm as cm
import matplotlib.colors as mcolors
import matplotlib.patches as mpatches
import matplotlib.ticker as mticker
import matplotlib.animation as manim_mod
import matplotlib.gridspec as mgridspec
import matplotlib.lines as mlines
import matplotlib.image as mimage
import matplotlib.text as mtext
import matplotlib.collections as mcollections
import matplotlib.path as mpath
import matplotlib.transforms as mtransforms
import matplotlib.legend as mlegend
import matplotlib.artist as martist
import matplotlib.axes as maxes
import matplotlib.axis as maxis
import matplotlib.colorbar as mcolorbar
import matplotlib.contour as mcontour
import matplotlib.dates as mdates
import matplotlib.scale as mscale
import matplotlib.widgets as mwidgets
import matplotlib.offsetbox as moffsetbox
import matplotlib.cbook as mcbook
import matplotlib.spines as mspines
import matplotlib.table as mtable
import matplotlib.markers as mmarkers
import matplotlib.patheffects as mpatheffects
import matplotlib.font_manager as mfm
import matplotlib.backend_bases as mbb
import matplotlib.style as mstyle
import matplotlib.projections
import matplotlib.tri

t("matplotlib version", lambda: matplotlib.__version__)
t("plt.cm.viridis", lambda: plt.cm.viridis(0.5))
t("plt.cm.plasma", lambda: plt.cm.plasma(np.linspace(0,1,10)))
t("plt.cm.jet", lambda: plt.cm.jet(0.3))
t("cm.get_cmap", lambda: cm.get_cmap('coolwarm'))
t("colors.to_rgba('red')", lambda: mcolors.to_rgba('red'))
t("colors.to_rgba('#FF5500')", lambda: mcolors.to_rgba('#FF5500'))
t("colors.to_hex((1,0,0))", lambda: mcolors.to_hex((1,0,0)))
t("colors.Normalize", lambda: mcolors.Normalize(0,10)(5))
t("colors.LogNorm", lambda: mcolors.LogNorm(1,100)(10))
t("colors.CSS4_COLORS", lambda: len(mcolors.CSS4_COLORS) > 100)
t("patches.Circle", lambda: mpatches.Circle((0,0), 1))
t("patches.Rectangle", lambda: mpatches.Rectangle((0,0), 1, 1))
t("ticker.MaxNLocator", lambda: mticker.MaxNLocator(5))
t("ticker.FuncFormatter", lambda: mticker.FuncFormatter(lambda x,p: f'{x:.1f}'))
t("gridspec.GridSpec", lambda: mgridspec.GridSpec(2,2))
t("artist.Artist", lambda: martist.Artist())
t("dates.date2num", lambda: mdates.date2num(mdates.num2date(737000)))
t("scale.get_scale_names", lambda: mscale.get_scale_names())
t("style.available", lambda: len(mstyle.available) > 5)
t("import mpl_toolkits.mplot3d", lambda: __import__('mpl_toolkits.mplot3d'))
t("import mpl_toolkits.axes_grid1", lambda: __import__('mpl_toolkits.axes_grid1'))
t("import mpl_toolkits.axisartist", lambda: __import__('mpl_toolkits.axisartist'))

print(f"\n  All {len([m for m in dir() if m.startswith('m') and not m.startswith('make')])} matplotlib modules imported OK")

# ════════════════════════════════════════════════════
section("SYMPY")
# ════════════════════════════════════════════════════
from sympy import (symbols, solve, diff, integrate, sin, cos, exp, log,
    pi, oo, series, limit, Matrix, simplify, factor, expand, Eq, sqrt,
    Rational, Sum, Product, FiniteSet, Interval, latex, pprint, lambdify)

x, y, z = symbols('x y z')
t("symbols", lambda: symbols('a b c'))
t("solve quadratic", lambda: solve(x**2 - 5*x + 6, x))
t("diff", lambda: diff(sin(x)*exp(x), x))
t("integrate", lambda: integrate(x**2*cos(x), x))
t("limit", lambda: limit(sin(x)/x, x, 0))
t("series", lambda: series(exp(x), x, 0, 5))
t("Matrix", lambda: Matrix([[1,2],[3,4]]).det())
t("simplify", lambda: simplify((x**2-1)/(x-1)))
t("factor", lambda: factor(x**3 - 1))
t("expand", lambda: expand((x+y)**3))
t("Eq + solve", lambda: solve(Eq(x**2 + 2*x, 3), x))
t("Sum", lambda: Sum(1/x**2, (x, 1, oo)).doit())
t("lambdify", lambda: lambdify(x, sin(x)*exp(-x))(1.0))
t("latex", lambda: latex(integrate(exp(-x**2), x)))

# ════════════════════════════════════════════════════
section("NETWORKX")
# ════════════════════════════════════════════════════
import networkx as nx

t("Graph", lambda: nx.Graph())
t("erdos_renyi_graph", lambda: nx.erdos_renyi_graph(20, 0.3, seed=42))
t("shortest_path", lambda: nx.shortest_path(nx.path_graph(10), 0, 9))
t("pagerank", lambda: nx.pagerank(nx.erdos_renyi_graph(20, 0.3, seed=42)))
t("betweenness_centrality", lambda: nx.betweenness_centrality(nx.karate_club_graph()))
t("connected_components", lambda: list(nx.connected_components(nx.erdos_renyi_graph(20, 0.1, seed=42))))
t("minimum_spanning_tree", lambda: nx.minimum_spanning_tree(nx.complete_graph(5)))
t("barabasi_albert_graph", lambda: nx.barabasi_albert_graph(50, 2, seed=42))
t("watts_strogatz_graph", lambda: nx.watts_strogatz_graph(20, 4, 0.3, seed=42))
t("DiGraph", lambda: nx.DiGraph([(1,2),(2,3),(3,1)]))
t("topological_sort", lambda: list(nx.topological_sort(nx.DiGraph([(1,2),(2,3),(1,3)]))))

# ════════════════════════════════════════════════════
section("PIL / PILLOW")
# ════════════════════════════════════════════════════
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageEnhance

t("Image.new", lambda: Image.new('RGB', (100, 100), 'red'))
t("ImageDraw", lambda: ImageDraw.Draw(Image.new('RGB', (100, 100))))
t("ImageFilter.BLUR", lambda: Image.new('RGB', (50, 50)).filter(ImageFilter.BLUR))
t("ImageEnhance.Brightness", lambda: ImageEnhance.Brightness(Image.new('RGB', (50, 50))).enhance(1.5))
t("Image.resize", lambda: Image.new('RGB', (100, 100)).resize((50, 50)))
t("Image.rotate", lambda: Image.new('RGB', (100, 100)).rotate(45))
t("Image.convert", lambda: Image.new('RGB', (100, 100)).convert('L'))

# ════════════════════════════════════════════════════
section("OTHER LIBRARIES")
# ════════════════════════════════════════════════════
t("mpmath", lambda: __import__('mpmath').mp.dps == 15 or True)
t("mpmath.mpf", lambda: __import__('mpmath').mpf('3.14'))
t("bs4.BeautifulSoup", lambda: __import__('bs4').BeautifulSoup('<b>hi</b>', 'html.parser').b.text)
t("yaml.safe_load", lambda: __import__('yaml').safe_load('name: test'))
t("tqdm.tqdm", lambda: __import__('tqdm').tqdm)
t("rich.console", lambda: __import__('rich.console', fromlist=['Console']).Console)
t("click", lambda: __import__('click').command)
t("jsonschema.validate", lambda: __import__('jsonschema').validate({"name": "test"}, {"type": "object"}))
t("pygments.highlight", lambda: __import__('pygments').highlight)
t("pydub.AudioSegment", lambda: __import__('pydub').AudioSegment)
t("svgelements", lambda: __import__('svgelements').SVG)
t("packaging.version", lambda: __import__('packaging.version', fromlist=['Version']).Version('1.0.0'))
t("cffi", lambda: __import__('cffi').FFI)

# ════════════════════════════════════════════════════
section("FINAL RESULTS")
# ════════════════════════════════════════════════════
elapsed = time.time() - _t0
print(f"\n  PASSED: {_pass}")
print(f"  FAILED: {_fail}")
print(f"  TOTAL:  {_pass + _fail}")
print(f"  TIME:   {elapsed:.1f}s")
if _errors:
    print(f"\n  Failed tests:")
    for name, err in _errors:
        print(f"    ✗ {name}: {err}")
print(f"\n{'='*50}")
